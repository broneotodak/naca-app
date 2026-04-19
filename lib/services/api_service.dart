import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';

class ApiService {
  static Map<String, String> get _headers => {
    'Authorization': 'Bearer ${AppConfig.authToken}',
    'Content-Type': 'application/json',
  };

  static Future<Map<String, dynamic>> health() async {
    final res = await http.get(
      Uri.parse('${AppConfig.apiBaseUrl}/api/health'),
      headers: _headers,
    );
    return jsonDecode(res.body);
  }

  static Future<List<dynamic>> listSessions() async {
    final res = await http.get(
      Uri.parse('${AppConfig.apiBaseUrl}/api/sessions'),
      headers: _headers,
    );
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> createSession(String name, String projectDir) async {
    final res = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/sessions'),
      headers: _headers,
      body: jsonEncode({'name': name, 'projectDir': projectDir}),
    );
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> startSession(String id) async {
    final res = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/sessions/$id/start'),
      headers: _headers,
    );
    return jsonDecode(res.body);
  }

  static Future<void> stopSession(String id) async {
    await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/sessions/$id/stop'),
      headers: _headers,
    );
  }

  static Future<void> deleteSession(String id) async {
    await http.delete(
      Uri.parse('${AppConfig.apiBaseUrl}/api/sessions/$id'),
      headers: _headers,
    );
  }

  static Future<void> renameSession(String id, String name) async {
    await http.patch(
      Uri.parse('${AppConfig.apiBaseUrl}/api/sessions/$id'),
      headers: _headers,
      body: jsonEncode({'name': name}),
    );
  }

  static Future<Map<String, dynamic>> getHistory(String id) async {
    final res = await http.get(
      Uri.parse('${AppConfig.apiBaseUrl}/api/sessions/$id/history'),
      headers: _headers,
    );
    return jsonDecode(res.body);
  }

  static Future<Map<String, dynamic>> uploadImage(String base64Data, String filename) async {
    final res = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}/api/upload'),
      headers: _headers,
      body: jsonEncode({'data': base64Data, 'filename': filename}),
    );
    return jsonDecode(res.body);
  }
}
