import 'package:flutter_tts/flutter_tts.dart';

class XiaozhiSpeechService {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.42);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _configured = true;
  }

  Future<void> speakActivationCode(String code) async {
    await _configure();
    final spaced = code.split('').join('，');
    await _tts.stop();
    await _tts.speak('请在小智控制台输入设备验证码：$spaced');
  }

  Future<void> stop() => _tts.stop();
}
