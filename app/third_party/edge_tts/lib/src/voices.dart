import 'dart:convert';

import 'constants.dart';
import 'drm.dart';
import 'http_client.dart';

/// Represents a Microsoft Edge neural TTS voice.
class Voice {
  final String name;
  final String shortName;
  final String gender;
  final String locale;
  final String language;
  final String friendlyName;
  final String status;
  final String suggestedCodec;
  final Map<String, dynamic>? voiceTag;

  Voice({
    required this.name,
    required this.shortName,
    required this.gender,
    required this.locale,
    required this.language,
    required this.friendlyName,
    required this.status,
    required this.suggestedCodec,
    this.voiceTag,
  });

  factory Voice.fromJson(Map<String, dynamic> json) {
    final locale = json['Locale'] as String;
    return Voice(
      name: json['Name'] as String,
      shortName: json['ShortName'] as String,
      gender: json['Gender'] as String,
      locale: locale,
      language: locale.split('-').first,
      friendlyName: json['FriendlyName'] as String,
      status: json['Status'] as String,
      suggestedCodec: json['SuggestedCodec'] as String,
      voiceTag: json['VoiceTag'] as Map<String, dynamic>?,
    );
  }

  @override
  String toString() => '$shortName ($gender, $locale)';
}

/// Manages voice listing and filtering.
class VoicesManager {
  final List<Voice> _voices;

  VoicesManager._(this._voices);

  /// Fetches the voice list from Microsoft's API and creates a manager.
  static Future<VoicesManager> create() async {
    final voices = await listVoices();
    return VoicesManager._(voices);
  }

  /// All available voices.
  List<Voice> get voices => List.unmodifiable(_voices);

  /// Find voices matching the given criteria.
  List<Voice> find({
    String? gender,
    String? locale,
    String? language,
    String? name,
  }) {
    return _voices.where((v) {
      if (gender != null && v.gender.toLowerCase() != gender.toLowerCase()) {
        return false;
      }
      if (locale != null && v.locale.toLowerCase() != locale.toLowerCase()) {
        return false;
      }
      if (language != null &&
          v.language.toLowerCase() != language.toLowerCase()) {
        return false;
      }
      if (name != null &&
          !v.shortName.toLowerCase().contains(name.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }
}

/// Fetches the list of available voices from Microsoft's API.
Future<List<Voice>> listVoices({int retryCount = 0}) async {
  final gec = generateSecMsGec();
  final muid = generateMuid();
  final url = Uri.parse(
    '$voiceListUrl?trustedclienttoken=$trustedClientToken'
    '&Sec-MS-GEC=$gec'
    '&Sec-MS-GEC-Version=$secMsGecVersion',
  );

  final client = createTtsHttpClient();
  try {
    final request = await client.getUrl(url);

    voiceHeaders.forEach((key, value) {
      request.headers.set(key, value);
    });
    request.headers.set('Cookie', 'muid=$muid;');

    final response = await request.close();

    if (response.statusCode == 403 && retryCount < 2) {
      final serverDate = response.headers.value('date');
      if (serverDate != null) {
        updateClockSkew(serverDate);
      }
      await response.drain<void>();
      return listVoices(retryCount: retryCount + 1);
    }

    if (response.statusCode != 200) {
      final body = await response.transform(utf8.decoder).join();
      throw EdgeTtsException(
        'Failed to fetch voices: HTTP ${response.statusCode}\n$body',
      );
    }

    final body = await response.transform(utf8.decoder).join();
    final List<dynamic> voiceList = json.decode(body) as List<dynamic>;
    return voiceList
        .map((v) => Voice.fromJson(v as Map<String, dynamic>))
        .toList();
  } finally {
    client.close();
  }
}

/// Exception thrown by edge_tts operations.
class EdgeTtsException implements Exception {
  final String message;
  EdgeTtsException(this.message);

  @override
  String toString() => 'EdgeTtsException: $message';
}
