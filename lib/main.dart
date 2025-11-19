// lib/main.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Voice Assistant',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: VoiceAssistantScreen(),
    );
  }
}

class VoiceAssistantScreen extends StatefulWidget {
  @override
  _VoiceAssistantScreenState createState() {
    return _VoiceAssistantScreenState();
  }
}

typedef ActionHandler = Future<void> Function(Map<String, dynamic> params);

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen>
    with TickerProviderStateMixin {
  late FlutterTts _flutterTts;
  late GenerativeModel _model;
  late AnimationController _animationController;
  late Animation<double> _animation;
  SpeechToText _speech = SpeechToText();
  PorcupineManager? _porcupineManager;

  bool _isListening = false;
  bool _speechEnabled = false;
  String _wordsSpoken = "";
  double _confidenceLevel = 0;
  String _response = "";
  bool _isProcessing = false;
  String _text = "Say 'Hey Maddy' to wake me up...";
  bool _wakeHandling = false; // prevents re-entrancy on wake callback
  DateTime? _lastWake;
  final Duration _wakeDebounce = Duration(milliseconds: 700); // tune if needed

  late final String GEMINI_API_KEY =
      const String.fromEnvironment('GEMINI_API_KEY');

  // Action map (whitelist)
  late final Map<String, ActionHandler> _actionMap;

  Future<void> _requestAndInitWake() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      setState(() {
        _text = "Microphone permission required for wake word.";
      });
      return;
    }
    await _initWakeWord();
  }

  Future<void> _initWakeWord() async {
    try {
      print("lodaaa");
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
          "FouyQPzbaja9xnwOWLHaImUAPI7O2U8a1cCIVasjVnFAyN5U6+fThw==", // get from Picovoice Console
          [
            "assets/Hey-Panda_en_android_v3_0_0.ppn" // for Android
            // use "assets/hey_maddy_ios.ppn" on iOS
          ],
          _wakeWordCallback
          // (){}
          // print
          );
      try {
        await _porcupineManager!.start();
        setState(() => _text = "Listening for wake word: Hey Maddy...");
      } on PorcupineException catch (ex) {
        print("Porcupine start failed: $ex");
        setState(() => _text = "Wake word engine failed to start.");
      }
    } catch (e) {
      print("Wake word init error: $e");
      setState(() {
        _text = "Wake word init failed: $e";
      });
    }
  }

  // void _wakeWordCallback(int keywordIndex) async {
  //   try {
  //     // Immediately stop porcupine so the mic is free for speech_to_text
  //     await _porcupineManager?.stop();
  //   } catch (e) {
  //     print("Error stopping porcupine: $e");
  //   }

  //   setState(() {
  //     _text = "Wake word detected — listening...";
  //   });

  //   // Short delay to ensure audio device is released
  //   // await Future.delayed(Duration(milliseconds: 200));

  //   // Start STT (this requests mic permission inside _startListening)
  //   if (!_isListening && _speechEnabled) {
  //     _startListening();
  //   }
  // }
  void _wakeWordCallback(int keywordIndex) async {
    // debounce
    final now = DateTime.now();
    if (_lastWake != null && now.difference(_lastWake!) < _wakeDebounce) {
      print("Wake ignored (debounced)");
      return;
    }
    _lastWake = now;

    if (_wakeHandling) {
      print("Already handling a wake");
      return;
    }
    _wakeHandling = true;

    try {
      // stop porcupine and give audio device a small moment to release
      try {
        await _porcupineManager?.stop();
      } catch (e) {
        print("Error stopping porcupine: $e");
      }

      // Very small delay helps the audio device release on some devices
      await Future.delayed(Duration(milliseconds: 200));

      setState(() {
        _text = "Wake word detected — listening...";
      });

      if (!_isListening && _speechEnabled) {
        _startListening();
      }
    } finally {
      // we don't immediately allow new wake handling; let _restartWakeWord reset it
      _wakeHandling = false;
    }
  }

  Future<bool> _ensureContactsPermission() async {
    try {
      // flutter_contacts has its own permission helper
      final granted = await FlutterContacts.requestPermission(readonly: true);
      print("fjknf $granted");
      if (!granted) {
        // fallback: show a snackbar and optionally open app settings
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Contacts permission required to use names."),
          action: SnackBarAction(
            label: "Settings",
            onPressed: () => openAppSettings(),
          ),
        ));
      }
      return granted;
    } catch (e) {
      print("Contacts permission error: $e");
      return false;
    }
  }

  String? _selectBestPhone(Contact contact) {
    print(contact.phones);
    if (contact.phones.isEmpty) return null;
    // Prefer a phone whose label contains 'mobile' or 'cell'
    for (final p in contact.phones) {
      final label = (p.label ?? '').toString().toLowerCase();
      if (label.contains('mobile') ||
          label.contains('cell') ||
          label.contains('m')) {
        return p.number;
      }
    }
    // otherwise return the first
    return contact.phones.first.number;
  }

  Future<Contact?> _findContactByName(String name) async {
    try {
      print("jfnjejenendendndjndj3d $name");
      if (name.trim().isEmpty) return null;

      print("contacfnftrr");
      final granted = await _ensureContactsPermission();
      if (!granted) return null;

      // get all contacts with phones (you can optimize by searching on native side if needed)
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      final needle = name.toLowerCase().trim();

      print(contacts);

      // 1) exact displayName match
      for (final c in contacts) {
        final display = (c.displayName ?? '').toLowerCase();
        if (display == needle) return c;
      }

      // 2) contains match
      for (final c in contacts) {
        final display = (c.displayName ?? '').toLowerCase();
        if (display.contains(needle)) return c;
      }

      // 3) split names and match first or last name
      final parts = needle.split(' ');
      for (final c in contacts) {
        final first = (c.name?.first ?? '').toLowerCase();
        final last = (c.name?.last ?? '').toLowerCase();
        for (final p in parts) {
          if (p.isEmpty) continue;
          if (first == p ||
              last == p ||
              first.contains(p) ||
              last.contains(p)) {
            return c;
          }
        }
      }

      // not found
      return null;
    } catch (e) {
      print("Error in _findContactByName: $e");
      return null;
    }
  }

// Minimal normalization: ensure leading + if missing and looks like local number
  String _normalizePhoneForWhatsApp(String raw) {
    String s = raw.replaceAll(RegExp(r'\s+|-|\(|\)'), '');
    if (s.startsWith('0')) {
      // This is a naive assumption — better to detect country code in production
      // You may want to add a default country code or ask the user
      s = s; // keep as-is; WhatsApp may accept local numbers on device
    }
    return s;
  }

  @override
  void initState() {
    super.initState();

    initializeSpeech();
    initializeTTS();
    initializeGemini();
    // _initWakeWord();
    _requestAndInitWake();

    _animationController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    // Initialize action map after initializing instance methods
    _actionMap = {
      'open_app': _handleOpenApp,
      'open_url': _handleOpenUrl,
      'search_web': _handleSearchWeb,
      'send_whatsapp': _handleSendWhatsApp,
      'dial_contact': _handleDialContact,
      // Add more actions and handlers here as needed
    };
  }

  void initializeSpeech() async {
    _speechEnabled = await _speech.initialize(
      onStatus: _statusListener,
      onError: (error) => print('Speech error: $error'),
      // debugLogging: true
    );
    setState(() {});
  }

  void initializeTTS() async {
    _flutterTts = FlutterTts();
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  void initializeGemini() {
    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: GEMINI_API_KEY,
    );
  }

  Future<void> _startListening() async {
    if (!_speechEnabled) return;

    final micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      final newStatus = await Permission.microphone.request();
      if (!newStatus.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Microphone permission denied')));
        return;
      }
    }

    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        listenOptions: SpeechListenOptions(
            partialResults: true,
            listenMode: ListenMode.dictation,
            cancelOnError: true),
        pauseFor: const Duration(seconds: 6),
        listenFor: const Duration(seconds: 15),
        onSoundLevelChange: (level) {},
      );

      setState(() {
        _isListening = true;
        _wordsSpoken = "";
        _confidenceLevel = 0;
      });
    } catch (e) {
      print("Error starting STT: $e");
      setState(() => _isListening = false);
    }
  }

  // void _startListening() async {
  //   if (!_speechEnabled) return;
  //   await Permission.microphone.request();

  //   await _speech.listen(
  //     onResult: _onSpeechResult,
  //     listenOptions: SpeechListenOptions(
  //         partialResults: true, listenMode: ListenMode.dictation),
  //     pauseFor: const Duration(seconds: 4), // stop after 2s of silence
  //     listenFor: const Duration(seconds: 15), // total limit
  //     // localeId: 'en_IN',
  //     onSoundLevelChange: (level) {
  //       // optional: show mic level for UX feedback
  //       // print('sound level: $level');
  //     },
  //     // cancelOnError: true,
  //   );

  //   setState(() {
  //     _isListening = true;
  //     _wordsSpoken = "";
  //     _confidenceLevel = 0;
  //   });
  // }

  void _stopListening() async {
    await _speech.stop();
    setState(() {
      _isListening = false;
    });

    // if (_wordsSpoken.isNotEmpty) {
    //   await _processVoiceCommand(_wordsSpoken);
    // }
  }

  void _statusListener(String status) async {
    print('Speech status: $status');

    if (status == 'notListening' && _isListening) {
      print("Speech stopped automatically");
      setState(() => _isListening = false);

      if (_wordsSpoken.isNotEmpty) {
        _processVoiceCommand(_wordsSpoken); // Call your Gemini API here
      }
      await Future.delayed(Duration(milliseconds: 150));

      _restartWakeWord(); // Resume wake word detection
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _wordsSpoken = result.recognizedWords;
      _confidenceLevel = result.confidence;
    });

    // handle final result asynchronously
    if (result.finalResult) {
      _onFinalSpeechResult();
    }
  }

  Future<void> _onFinalSpeechResult() async {
    try {
      await _speech.stop();
    } catch (e) {
      print("Error stopping STT after final result: $e");
    }

    // // process the command (this will call Gemini and perform actions)
    // if (_wordsSpoken.isNotEmpty) {
    //   await _processVoiceCommand(_wordsSpoken);
    // }

    // // restart wake word detection (with small delay)
    // await Future.delayed(Duration(milliseconds: 150));
    // await _restartWakeWord();
  }

  Future<void> _restartWakeWord() async {
    try {
      // short delay to avoid immediate restart collisions
      await Future.delayed(Duration(milliseconds: 200));
      await _porcupineManager?.start();
      setState(() {
        _text = "Listening for wake word: Hey Maddy...";
      });
    } catch (e) {
      print("Failed to restart porcupine: $e");
      setState(() {
        _text = "Wake word engine unavailable.";
      });
    }
  }

  // ----------------------------
  // Core: process voice command -> ask LLM -> run action handler
  // ----------------------------
  Future<void> _processVoiceCommand(String command) async {
    setState(() {
      _isProcessing = true;
      _response = "";
    });

    final prompt = """
You are a voice assistant that MUST return a valid JSON object (only JSON, no commentary) describing the action to run and the parameters for that action.

Analyze the user's voice command: "$command"

Return either a) an action to run OR b) a conversational reply.

Format A (action):
{
  "action": "<action_key>",           // one of: open_app, open_url, search_web, send_whatsapp, dial_contact, conversation
  "params": {                         // parameters needed for the action (may be empty)
    "app_name": "WhatsApp",
    "package_name": "com.whatsapp",
    "url_scheme": "whatsapp://send?text=Hello",
    "url": "https://example.com",
    "query": "search text",
    "text": "message to send",
    "contact_name:contact name of person
    "phone": "+911234567890"
  },
  "response": "Short user-facing response to speak (one sentence)."
}

Format B (conversation):
{
  "action": "conversation",
  "params": {},
  "response": "Your conversational text reply here."
}

Rules:
- Return strictly valid JSON only (no surrounding text, no backticks).
- Prefer package_name and url_scheme when instructing to open apps.
- If you can **confidently answer directly** (e.g., factual, casual, or general question), choose `"action": "conversation"`.
- Use `"search_web"` **only** when you **don’t know** or **need to fetch** fresh data (e.g., weather, live scores, trending news). 
- If uncertain about package_name use app_name and leave package_name empty.
- For sending WhatsApp messages use action send_whatsapp with params.phone and params.text or url_scheme.
- Keep response short (<= 30 words).
- If multiple actions possible, choose the single best action.
""";

    final content = [Content.text(prompt)];
    late final GenerateContentResponse response;
    try {
      response = await _model.generateContent(content);
    } catch (e) {
      final msg = "Error contacting assistant.";
      setState(() {
        _response = msg;
        _isProcessing = false;
      });
      await _flutterTts.speak(msg);
      return;
    }

    String responseText = response.text ?? "";
    responseText =
        responseText.replaceAll('```json', '').replaceAll('```', '').trim();

    dynamic jsonResponse;
    try {
      jsonResponse = json.decode(responseText);
    } catch (e) {
      // If parsing fails, speak model raw response and stop
      setState(() {
        _response = responseText;
        _isProcessing = false;
      });
      await _flutterTts.speak(_response);
      return;
    }

    final String action = (jsonResponse['action'] ?? 'conversation').toString();
    final Map<String, dynamic> params =
        Map<String, dynamic>.from(jsonResponse['params'] ?? {});
    final String modelSpokenResponse =
        (jsonResponse['response'] ?? '').toString();

    // Speak model response first (if provided)
    if (modelSpokenResponse.isNotEmpty) {
      setState(() => _response = modelSpokenResponse);
      await _flutterTts.speak(modelSpokenResponse);
    }

    // No further action for conversation
    if (action == 'conversation') {
      setState(() => _isProcessing = false);
      return;
    }

    final handler = _actionMap[action];
    if (handler == null) {
      final msg = "Sorry, I can't perform that action.";
      setState(() => _response = msg);
      await _flutterTts.speak(msg);
      setState(() => _isProcessing = false);
      return;
    }

    try {
      await handler(params);
    } catch (e) {
      final msg = "Failed to perform action: ${e.toString()}";
      setState(() => _response = msg);
      await _flutterTts.speak(msg);
    }

    setState(() {
      _isProcessing = false;
    });
  }

  Future<bool> _confirmAction(String message) async {
    // speak the question
    await _flutterTts.speak(message);

    // show a dialog and return the user's choice (helpful on-screen fallback)
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text("Confirm"),
          content: Text(message),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text("No")),
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text("Yes")),
          ],
        );
      },
    );

    return choice == true;
  }

  // ----------------------------
  // Handlers
  // ----------------------------
  Future<void> _handleSendWhatsApp(Map<String, dynamic> params) async {
    final String urlSchemeFromModel = (params['url_scheme'] ?? '').toString();
    final String phoneFromModel = (params['phone'] ?? '').toString();
    final String text = (params['text'] ?? '').toString();
    final String contactName = (params['contact_name'] ?? '').toString();

    // 1) If model provided an explicit url_scheme, try it
    if (urlSchemeFromModel.isNotEmpty) {
      final uri = Uri.tryParse(urlSchemeFromModel);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }

    // 2) If model provided an explicit phone, use it
    if (phoneFromModel.isNotEmpty) {
      final normalized = _normalizePhoneForWhatsApp(phoneFromModel);
      final encoded = Uri.encodeComponent(text);
      final uri = Uri.parse('whatsapp://send?phone=$normalized&text=$encoded');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }

    // 3) If model provided contact_name, look up contacts
    if (contactName.isNotEmpty) {
      final contact = await _findContactByName(contactName);
      print("contsfj nameenej");
      if (contact != null) {
        print(contactName);
        final best = _selectBestPhone(contact);
        if (best != null) {
          final normalized = _normalizePhoneForWhatsApp(best);
          final encoded = Uri.encodeComponent(text);
          final uri =
              Uri.parse('whatsapp://send?phone=$normalized&text=$encoded');

          // Ask for confirmation before sending (safety)
          // final confirm = await _confirmAction("Send WhatsApp message to ${contact.displayName}?");
          // if (!confirm) {
          //   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Cancelled")));
          //   return;
          // }

          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            return;
          } else {
            // Fallback: open WhatsApp home
            await _handleOpenApp(
                {'package_name': 'com.whatsapp', 'app_name': 'WhatsApp'});
            return;
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content:
                  Text("No phone number found for ${contact.displayName}")));
          return;
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Contact named '$contactName' not found.")));
      }
    }

    // 4) final fallback: open WhatsApp app or Play Store
    await _handleOpenApp(
        {'package_name': 'com.whatsapp', 'app_name': 'WhatsApp'});
  }

  Future<void> _handleOpenApp(Map<String, dynamic> params) async {
    final String package = (params['package_name'] ?? '').toString();
    final String urlScheme = (params['url_scheme'] ?? '').toString();
    final String appName = (params['app_name'] ?? '').toString();

    if (Platform.isAndroid) {
      if (package.isNotEmpty) {
        await AppLauncher.openApp(package);
        return;
      }
      if (urlScheme.isNotEmpty) {
        final uri = Uri.tryParse(urlScheme);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      }
      if (appName.isNotEmpty) {
        final Uri play = Uri.parse(
            'https://play.google.com/store/search?q=${Uri.encodeComponent(appName)}&c=apps');
        if (await canLaunchUrl(play)) {
          await launchUrl(play, mode: LaunchMode.externalApplication);
        }
        return;
      }
    } else if (Platform.isIOS) {
      if (urlScheme.isNotEmpty) {
        final uri = Uri.tryParse(urlScheme);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      }
      if (appName.isNotEmpty) {
        final Uri store = Uri.parse(
            'https://apps.apple.com/us/search?term=${Uri.encodeComponent(appName)}');
        if (await canLaunchUrl(store)) {
          await launchUrl(store, mode: LaunchMode.externalApplication);
          return;
        }
      }
    }

    final message = "Couldn't open app. It may not be installed.";
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleOpenUrl(Map<String, dynamic> params) async {
    final String url = (params['url'] ?? '').toString();
    if (url.isEmpty) {
      throw Exception("No URL provided");
    }
    final uri = Uri.tryParse(url);
    if (uri == null) throw Exception("Invalid URL");
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw Exception("Unable to open URL");
    }
  }

  Future<void> _handleSearchWeb(Map<String, dynamic> params) async {
    final String query = (params['query'] ?? '').toString();
    if (query.isEmpty) throw Exception("Empty search query");
    final Uri uri = Uri.parse(
        'https://www.google.com/search?q=${Uri.encodeComponent(query)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw Exception("Can't open browser");
    }
  }

  // Future<void> _handleSendWhatsApp(Map<String, dynamic> params) async {
  //   final String urlScheme = (params['url_scheme'] ?? '').toString();
  //   final String phone = (params['phone'] ?? '').toString();
  //   final String text = (params['text'] ?? '').toString();

  //   if (urlScheme.isNotEmpty) {
  //     final uri = Uri.tryParse(urlScheme);
  //     if (uri != null && await canLaunchUrl(uri)) {
  //       await launchUrl(uri, mode: LaunchMode.externalApplication);
  //       return;
  //     }
  //   }

  //   if (phone.isNotEmpty) {
  //     final encoded = Uri.encodeComponent(text);
  //     final uri = Uri.parse('whatsapp://send?phone=$phone&text=$encoded');
  //     if (await canLaunchUrl(uri)) {
  //       await launchUrl(uri, mode: LaunchMode.externalApplication);
  //       return;
  //     }
  //   }

  //   // fallback: try to open whatsapp app
  //   await _handleOpenApp(
  //       {'package_name': 'com.whatsapp', 'app_name': 'WhatsApp'});
  // }

  Future<void> _handleDialContact(Map<String, dynamic> params) async {
    final String contactName = (params['contact_name'] ?? '').toString();
    final String phoneFromModel = (params['phone'] ?? '').toString();

    String? phone;
    if (phoneFromModel.isNotEmpty) phone = phoneFromModel;
    if (contactName.isNotEmpty && (phone == null || phone.isEmpty)) {
      final contact = await _findContactByName(contactName);
      if (contact != null) phone = _selectBestPhone(contact);
    }

    if (phone == null || phone.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("No phone found to dial.")));
      return;
    }

    final normalized = _normalizePhoneForWhatsApp(phone);

    // Confirm with user first (recommended)
    // final confirm = await _confirmAction("Call $normalized now?");
    // if (!confirm) return;

    // REQUEST RUNTIME PERMISSION for CALL_PHONE
    final status = await Permission.phone.request();
    if (!status.isGranted) {
      // Show a message and optionally open app settings
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Phone permission denied. Can't place call."),
        action: SnackBarAction(
            label: "Settings", onPressed: () => openAppSettings()),
      ));
      return;
    }

    try {
      // flutter_phone_direct_caller places the call directly (ACTION_CALL)
      final bool? res = await FlutterPhoneDirectCaller.callNumber(normalized);
      if (res == false) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Failed to place call.")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error placing call: ${e.toString()}")));
    }
  }

  // ----------------------------
  // UI + rest of your code (mostly unchanged)
  // ----------------------------
  @override
  void dispose() {
    _animationController.dispose();
    try {
      _porcupineManager?.stop();
      _porcupineManager?.delete();
    } catch (e) {
      print("Error disposing porcupine: $e");
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.blue.shade900,
              Colors.black,
              Colors.purple.shade900,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Text(
                  'AI Voice Assistant',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              // Status indicator
              Container(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _speechEnabled ? Icons.mic : Icons.mic_off,
                      color: _speechEnabled ? Colors.green : Colors.red,
                    ),
                    SizedBox(width: 8),
                    Text(
                      _speechEnabled
                          ? 'Ready to listen'
                          : 'Speech not available',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Voice visualization
                    AnimatedBuilder(
                      animation: _animation,
                      builder: (context, child) {
                        return Transform.scale(
                          scale: _isListening ? _animation.value : 1.0,
                          child: Container(
                            width: 150,
                            height: 150,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  _isListening
                                      ? Colors.blue
                                      : Colors.grey.shade700,
                                  _isListening
                                      ? Colors.purple
                                      : Colors.grey.shade900,
                                ],
                              ),
                              boxShadow: _isListening
                                  ? [
                                      BoxShadow(
                                        color: Colors.blue.withOpacity(0.5),
                                        spreadRadius: 20,
                                        blurRadius: 30,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Icon(
                              _isListening ? Icons.mic : Icons.mic_none,
                              size: 60,
                              color: Colors.white,
                            ),
                          ),
                        );
                      },
                    ),

                    SizedBox(height: 30),

                    // Voice command text
                    if (_wordsSpoken.isNotEmpty)
                      Container(
                        margin: EdgeInsets.symmetric(horizontal: 20),
                        padding: EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border:
                              Border.all(color: Colors.white.withOpacity(0.2)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'You said:',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                            SizedBox(height: 5),
                            Text(
                              _wordsSpoken,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (_confidenceLevel > 0)
                              Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: LinearProgressIndicator(
                                  value: _confidenceLevel,
                                  backgroundColor:
                                      Colors.white.withOpacity(0.2),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.green),
                                ),
                              ),
                          ],
                        ),
                      ),

                    SizedBox(height: 20),

                    // Response text
                    if (_response.isNotEmpty)
                      Container(
                        margin: EdgeInsets.symmetric(horizontal: 20),
                        padding: EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border:
                              Border.all(color: Colors.green.withOpacity(0.3)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'Assistant:',
                              style: TextStyle(
                                color: Colors.green.shade200,
                                fontSize: 14,
                              ),
                            ),
                            SizedBox(height: 5),
                            Text(
                              _response,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),

                    SizedBox(height: 30),

                    // Processing indicator
                    if (_isProcessing)
                      Column(
                        children: [
                          CircularProgressIndicator(
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.blue),
                          ),
                          SizedBox(height: 10),
                          Text(
                            'Processing...',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              // Control buttons
              Padding(
                padding: const EdgeInsets.all(30.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Listen button
                    GestureDetector(
                      onTap: _speechEnabled && !_isProcessing
                          ? (_isListening ? _stopListening : _startListening)
                          : null,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: _speechEnabled && !_isProcessing
                                ? [Colors.blue, Colors.purple]
                                : [Colors.grey, Colors.grey.shade700],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.3),
                              spreadRadius: 2,
                              blurRadius: 5,
                            ),
                          ],
                        ),
                        child: Icon(
                          _isListening ? Icons.stop : Icons.mic,
                          size: 35,
                          color: Colors.white,
                        ),
                      ),
                    ),

                    // Clear button
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _wordsSpoken = "";
                          _response = "";
                          _confidenceLevel = 0;
                        });
                      },
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.red.withOpacity(0.8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.3),
                              spreadRadius: 2,
                              blurRadius: 5,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.clear,
                          size: 25,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------
// AppLauncher platform channel (uses your Android native implementation)
// ----------------------------
class AppLauncher {
  static const MethodChannel _channel = MethodChannel('app_launcher');

  static Future<void> openApp(String packageName) async {
    try {
      await _channel.invokeMethod('openApp', {"package": packageName});
    } on PlatformException catch (e) {
      print("Failed to open app: $e");
    }
  }
}
