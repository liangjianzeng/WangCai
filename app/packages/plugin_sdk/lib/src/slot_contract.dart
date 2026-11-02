/// **宿主槽契约表（P0 冻结件）**：宿主一次性把位置声明全，渲染可以分期落地。
///
/// 为什么一次冻结 11 个（而不是"先做 5 个以后再加"）：槽是**宿主与插件之间的契约**，
/// 加一个新位置很便宜，改一个已有位置的语义则要让所有已写好的插件返工。
/// 本表由 `test/slot_contract_test.dart` 钉死 —— **任何人改动它，测试立刻红**，
/// 逼他走"新增槽"而不是"偷改槽"（契约只加不改）。
///
/// 每条 `description` 都是评审必读：填这个槽要保证什么、能返回空吗、崩溃了会怎样。
library;

import 'slot.dart';

/// 宿主拥有的槽（owner = `app`）。
const List<SlotDef> kHostSlotContract = [
  SlotDef(
    id: 'app.input.left',
    kind: SlotKind.list,
    scope: SlotScope.sessionMaybe,
    ownerPluginId: 'app',
    description: '输入条左侧图标位（附件「+」等）。多个插件共存按 order 排；条目自己决定点击行为；'
        '能力不可用时应渲染置灰态而不是返回 null（否则用户找不到入口）。',
  ),
  SlotDef(
    id: 'app.input.right',
    kind: SlotKind.list,
    scope: SlotScope.sessionMaybe,
    ownerPluginId: 'app',
    description: '输入条右侧图标位（模型 chip 之后、发送键之前）。听写插件的主入口填这里。',
  ),
  SlotDef(
    id: 'app.input.activity',
    kind: SlotKind.list,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '输入条上方的活动条（"正在识别…"这类）。必须轻量：只允许一行文字 + 进度，不许放按钮组。',
  ),
  SlotDef(
    id: 'app.input.attachments',
    kind: SlotKind.list,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '待发送附件预览区。插件可插入自己形态的附件卡（例如"课本第 3 页"）。',
  ),
  SlotDef(
    id: 'app.composer.dock',
    kind: SlotKind.list,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '输入区下方的常驻坞（听写播控条的次选位置；比 takeover 温和，不吞掉输入框）。',
  ),
  SlotDef(
    id: 'app.input.dock',
    kind: SlotKind.single,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '整条输入区的**接管位**（single）：最低 priority 的存活者独占渲染。听写播放中把整条输入区换成播控条用这个。'
        '同 priority 冲突会报错并指名占用者；条目崩溃自动让位给下一个。',
    maxEntries: 4,
  ),
  SlotDef(
    id: 'app.input.overlay',
    kind: SlotKind.single,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '输入区之上的浮层（取景提示、识别中的全屏遮罩）。渲染在输入区 Stack 顶层。',
  ),
  SlotDef(
    id: 'app.composer.takeover',
    kind: SlotKind.chain,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '输入区接管链：按 priority 依次跑 select，第一个非 null 者当选。'
        'select 必须是纯函数（只看 ownerData），拒绝接管就返回 null，不许在组件内部再判断。',
  ),
  SlotDef(
    id: 'app.chat.node',
    kind: SlotKind.keyed,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '消息卡片按类型派发的插槽（key = 消息形态，如 wordList / practiceSheet）。'
        '同 key 再注册是替换；拼错的 key 永不渲染。',
  ),
  SlotDef(
    id: 'app.tool.view',
    kind: SlotKind.keyed,
    scope: SlotScope.session,
    ownerPluginId: 'app',
    description: '工具调用卡按工具名派发（key = 工具名）。对齐 DSH tool.call.toolview："a typo never renders"。',
  ),
  SlotDef(
    id: 'app.settings.section',
    kind: SlotKind.list,
    scope: SlotScope.root,
    ownerPluginId: 'app',
    description: '设置页分区。插件在这里放自己的设置卡；必须自带"恢复默认"入口。',
  ),
];

/// 插件面板（P6 落地）自己作为 owner 声明的槽 —— 契约同样在 P0 冻结，实现分期。
const List<SlotDef> kPanelSlotContract = [
  SlotDef(
    id: 'app.plugins.tab',
    kind: SlotKind.list,
    scope: SlotScope.root,
    ownerPluginId: 'app',
    description: '插件详情页的额外页签（体检结果、诊断树之外插件可再加自己的页）。',
  ),
  SlotDef(
    id: 'app.plugins.detail.action',
    kind: SlotKind.list,
    scope: SlotScope.root,
    ownerPluginId: 'app',
    description: '插件详情页底部的动作按钮位（"打开错词本"这类）。',
  ),
];

/// 全部已知宿主槽（校验"插件填的槽是否真实存在"时用）。
List<SlotDef> get allHostSlots => [...kHostSlotContract, ...kPanelSlotContract];

SlotDef? hostSlotDef(String id) {
  for (final d in allHostSlots) {
    if (d.id == id) return d;
  }
  return null;
}
