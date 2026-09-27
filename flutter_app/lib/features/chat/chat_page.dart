// lib/features/chat/chat_page.dart
// 小醒 AI 对话页 · SSE 流式打字动效 · 快捷回复 · 三姿态
// 醒伴 WakeMate Flutter APP

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/wakemate_theme.dart';
import '../../core/xiaozhi/xiaozhi_models.dart';
import '../../core/xiaozhi/xiaozhi_session.dart';
import '../../shared/widgets/xiaoxing_avatar.dart';

// 消息 UI 数据
class _UiMsg {
  final String role; // user | assistant
  final String content;
  final XiaoxingPose pose;
  final bool isStreaming;

  _UiMsg({
    required this.role,
    required this.content,
    this.pose = XiaoxingPose.calm,
    this.isStreaming = false,
  });

  _UiMsg copyWith({String? content, bool? isStreaming}) => _UiMsg(
        role: role,
        content: content ?? this.content,
        pose: pose,
        isStreaming: isStreaming ?? this.isStreaming,
      );
}

class ChatPage extends ConsumerStatefulWidget {
  final String? scene; // missed | null
  final String? drug;

  const ChatPage({super.key, this.scene, this.drug});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _controller = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_UiMsg> _messages = [];
  bool _sending = false;
  bool _voiceActive = false;
  XiaozhiConnectionState _xiaozhiState = XiaozhiConnectionState.uninitialized;
  String? _xiaozhiError;
  StreamSubscription<XiaozhiConnectionState>? _stateSubscription;
  StreamSubscription<XiaozhiTextEvent>? _eventSubscription;
  int? _streamingAgentIndex;
  XiaoxingPose _currentPose = XiaoxingPose.gentle;

  static const _quickReplies = [
    '今天按时了吗',
    '我漏服了',
    '修改提醒时间',
    '药吃完了怎么办',
    '睡不着怎么办',
  ];

  @override
  void initState() {
    super.initState();
    _greet();
    _connectXiaozhi();
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _eventSubscription?.cancel();
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _connectXiaozhi() {
    final session = ref.read(xiaozhiSessionProvider);
    _xiaozhiState = session.state;
    _stateSubscription = session.states.listen((state) {
      if (!mounted) return;
      setState(() {
        _xiaozhiState = state;
        _xiaozhiError = session.error;
      });
    });
    _eventSubscription = session.events.listen(_handleXiaozhiEvent);
    session.connect().catchError((error) {
      if (!mounted) return;
      setState(() => _xiaozhiError = error.toString());
    });
  }

  Future<void> _retryXiaozhi() async {
    final session = ref.read(xiaozhiSessionProvider);
    if (mounted) setState(() => _xiaozhiError = null);
    try {
      await session.connect();
    } catch (error) {
      if (mounted) setState(() => _xiaozhiError = error.toString());
    }
  }

  void _handleXiaozhiEvent(XiaozhiTextEvent event) {
    if (!mounted || event.text == null || event.text!.isEmpty) return;
    if (event.type == 'stt') {
      setState(() => _messages.add(_UiMsg(role: 'user', content: event.text!)));
      _scrollToBottom();
      return;
    }
    if (event.type == 'tts' && event.state == 'sentence_start') {
      final index = _streamingAgentIndex;
      if (index != null && index < _messages.length) {
        setState(() {
          final current = _messages[index];
          _messages[index] =
              current.copyWith(content: '${current.content}${event.text}');
        });
      } else {
        _appendAgent(event.text!, XiaoxingPose.calm);
      }
      _scrollToBottom();
    }
  }

  void _greet() {
    Future.delayed(const Duration(milliseconds: 400), () {
      if (widget.scene == 'missed') {
        _appendAgent(
          '检测到你错过了 ${widget.drug ?? "用药"} 的服药时间…',
          XiaoxingPose.soothe,
        );
        Future.delayed(const Duration(milliseconds: 800), () {
          _sendMessage('我漏服了');
        });
      } else {
        _appendAgent('嗨～我是小醒，你的小守夜灯，有什么想聊的吗？', XiaoxingPose.gentle);
      }
    });
  }

  void _appendAgent(String text, XiaoxingPose pose) {
    setState(() {
      _messages.add(_UiMsg(role: 'assistant', content: text, pose: pose));
      _currentPose = pose;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage([String? quickText]) async {
    final text = quickText ?? _controller.text.trim();
    if (text.isEmpty || _sending) return;

    _controller.clear();
    setState(() {
      _sending = true;
      _messages.add(_UiMsg(role: 'user', content: text));
    });
    _scrollToBottom();

    // 官方小智 TTS 会通过事件流返回分句；先保留一个稳定的消息位置。
    final streamingIdx = _messages.length;
    _streamingAgentIndex = streamingIdx;
    setState(() {
      _messages.add(_UiMsg(
        role: 'assistant',
        content: '',
        isStreaming: true,
        pose: XiaoxingPose.calm,
      ));
    });

    try {
      await ref.read(xiaozhiSessionProvider).sendText(text);
      if (mounted && streamingIdx < _messages.length) {
        setState(() => _messages[streamingIdx] =
            _messages[streamingIdx].copyWith(isStreaming: false));
      }
    } catch (e) {
      if (mounted && streamingIdx < _messages.length) {
        setState(() {
          _messages[streamingIdx] = _UiMsg(
            role: 'assistant',
            content: '小智连接失败：$e',
            pose: XiaoxingPose.calm,
          );
        });
      }
    }

    _streamingAgentIndex = null;
    if (mounted) setState(() => _sending = false);
    _scrollToBottom();
  }

  Future<void> _toggleVoice() async {
    if (_voiceActive) {
      try {
        await ref.read(xiaozhiSessionProvider).stopVoice();
      } finally {
        if (mounted) setState(() => _voiceActive = false);
      }
      return;
    }
    try {
      await ref.read(xiaozhiSessionProvider).startVoice();
      if (mounted) setState(() => _voiceActive = true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('语音连接失败：$error')),
      );
    }
  }

  String _connectionLabel() {
    switch (_xiaozhiState) {
      case XiaozhiConnectionState.activationRequired:
      case XiaozhiConnectionState.activating:
        return '等待设备激活';
      case XiaozhiConnectionState.otaLoading:
      case XiaozhiConnectionState.connecting:
      case XiaozhiConnectionState.handshaking:
        return '连接小智中';
      case XiaozhiConnectionState.ready:
      case XiaozhiConnectionState.listening:
      case XiaozhiConnectionState.speaking:
        return '在线 · 小守夜灯';
      case XiaozhiConnectionState.error:
        return '小智连接失败';
      default:
        return '未连接小智';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WMColors.bgPage,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 20),
          onPressed: () => context.go('/home'),
        ),
        title: Row(
          children: [
            XiaoxingAvatar(pose: _currentPose, size: 32),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('小醒',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: WMColors.brandSecondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(_connectionLabel(),
                        style: TextStyle(
                            fontSize: 11, color: WMColors.brandSecondary)),
                  ],
                ),
              ],
            ),
          ],
        ),
        titleSpacing: 0,
      ),
      body: Column(
        children: [
          if (_xiaozhiState == XiaozhiConnectionState.activationRequired ||
              _xiaozhiState == XiaozhiConnectionState.activating)
            _buildActivationBanner(ref.read(xiaozhiSessionProvider)),
          if (_xiaozhiState == XiaozhiConnectionState.error &&
              _xiaozhiError != null)
            _buildErrorBanner(_xiaozhiError!),
          // 消息列表
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(WMSpacing.md),
              itemCount: _messages.length,
              itemBuilder: (_, i) => _buildBubble(_messages[i]),
            ),
          ),
          // 快捷回复
          Container(
            height: 48,
            decoration: const BoxDecoration(
              color: WMColors.bgPage,
              border: Border(top: BorderSide(color: WMColors.ink200)),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: WMSpacing.md, vertical: 8),
              itemCount: _quickReplies.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => _sendMessage(_quickReplies[i]),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: WMColors.brandPrimarySoft,
                    border: Border.all(color: WMColors.brandPrimary),
                    borderRadius: WMRadius.pill,
                  ),
                  child: Text(_quickReplies[i],
                      style: const TextStyle(
                          fontSize: 13,
                          color: WMColors.brandPrimary,
                          fontWeight: FontWeight.w500)),
                ),
              ),
            ),
          ),
          // 输入栏
          Container(
            color: WMColors.bgCard,
            padding: EdgeInsets.fromLTRB(
              WMSpacing.md,
              10,
              WMSpacing.md,
              10 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: _voiceActive ? '停止语音' : '开始语音',
                  onPressed: _sending ? null : _toggleVoice,
                  icon: Icon(_voiceActive
                      ? Icons.stop_circle_outlined
                      : Icons.mic_none_rounded),
                  color: _voiceActive
                      ? WMColors.brandAccent
                      : WMColors.brandPrimary,
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: '和小醒说说话...',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _sending ? null : _sendMessage,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _sending ? WMColors.ink200 : WMColors.brandPrimary,
                      borderRadius: WMRadius.md,
                    ),
                    child: const Icon(Icons.send_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivationBanner(XiaozhiSession session) {
    final code = session.activationCode;
    final message = session.activationMessage;
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(horizontal: WMSpacing.md, vertical: 10),
      color: WMColors.brandAccentSoft,
      child: Row(
        children: [
          const Icon(Icons.link_rounded, color: WMColors.brandAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  code == null ? '请在小智控制台完成设备激活' : '小智设备验证码：$code',
                  style: const TextStyle(
                      color: WMColors.ink900, fontWeight: FontWeight.w600),
                ),
                if (message != null && message.trim().isNotEmpty)
                  Text(
                    message.replaceAll('\\n', ' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: WMColors.ink700, fontSize: 12, height: 1.3),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制验证码',
            onPressed: code == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('验证码已复制')),
                    );
                  },
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: '再次播报验证码',
            onPressed: code == null
                ? null
                : () => session.speech.speakActivationCode(code),
            icon: const Icon(Icons.volume_up_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String error) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(horizontal: WMSpacing.md, vertical: 8),
      color: WMColors.dangerSoft,
      child: Row(
        children: [
          Expanded(
            child: Text(error, style: const TextStyle(color: WMColors.danger)),
          ),
          IconButton(
            tooltip: '重试小智连接',
            onPressed: _retryXiaozhi,
            icon: const Icon(Icons.refresh_rounded, color: WMColors.danger),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(_UiMsg msg) {
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: WMSpacing.md),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            XiaoxingAvatar(pose: msg.pose, size: 24),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? WMColors.brandPrimary : WMColors.bgCard,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(isUser ? 14 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 14),
                ),
                boxShadow: isUser ? [] : WMShadows.card,
              ),
              child: msg.isStreaming
                  ? _buildTypingDots()
                  : Text(
                      msg.content,
                      style: TextStyle(
                        fontSize: 15,
                        color: isUser ? Colors.white : WMColors.ink900,
                        height: 1.6,
                      ),
                    ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildTypingDots() {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) => _Dot(delay: i * 150)),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000));
    _anim = Tween<double>(begin: 0, end: -6).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Transform.translate(
          offset: Offset(0, _anim.value),
          child: Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: WMColors.ink300,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
