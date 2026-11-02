const String trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const String chromiumFullVersion = '143.0.3650.75';
const String chromiumMajorVersion = '143';
// 2026-10-10 起微软免费 readaloud 端点强制 v2 token：前缀必须是 `2-`，且 token
// 必须是 `<16hex>-<64hex>`（见 drm.dart / gec_v2.dart）。只改前缀或只改 token
// 都仍然 403 —— 两者必须成对切换。
const String secMsGecVersion = '2-$chromiumFullVersion';

const String baseUrl =
    'speech.platform.bing.com/consumer/speech/synthesize/readaloud';
const String wssUrl = 'wss://$baseUrl/edge/v1';
const String voiceListUrl = 'https://$baseUrl/voices/list';

const String defaultVoice = 'en-US-EmmaMultilingualNeural';
const String audioFormat = 'audio-24khz-48kbitrate-mono-mp3';
const int maxChunkSize = 4096;
const int offsetCompensationPadding = 8750000; // 100-nanosecond intervals
const int winEpoch = 11644473600; // seconds between 1601-01-01 and 1970-01-01

const Map<String, String> baseHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/$chromiumMajorVersion.0.0.0 Safari/537.36 '
      'Edg/$chromiumMajorVersion.0.0.0',
  'Accept-Encoding': 'gzip, deflate, br, zstd',
  'Accept-Language': 'en-US,en;q=0.9',
};

const Map<String, String> wssHeaders = {
  ...baseHeaders,
  'Pragma': 'no-cache',
  'Cache-Control': 'no-cache',
  'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
};

const Map<String, String> voiceHeaders = {
  ...baseHeaders,
  'Authority': 'speech.platform.bing.com',
  'Sec-CH-UA':
      '" Not;A Brand";v="99", "Microsoft Edge";v="$chromiumMajorVersion", '
      '"Chromium";v="$chromiumMajorVersion"',
  'Sec-CH-UA-Mobile': '?0',
  'Accept': '*/*',
  'Sec-Fetch-Site': 'none',
  'Sec-Fetch-Mode': 'cors',
  'Sec-Fetch-Dest': 'empty',
};
