import 'grammar.dart';
import 'uri.dart';
import 'utils.dart';

class NameAddrHeader {
  NameAddrHeader(URI? uri, String? display_name,
      [Map<dynamic, dynamic>? parameters]) {
    // Checks.
    if (uri == null) {
      throw AssertionError('missing or invalid "uri" = $uri parameter');
    }

    // Initialize parameters.
    _uri = uri;
    _parameters = <dynamic, dynamic>{};
    _display_name = display_name;

    if (parameters != null) {
      parameters.forEach((dynamic key, dynamic param) {
        setParam(key, param);
      });
    }
  }
  URI? _uri;
  Map<dynamic, dynamic>? _parameters;
  String? _display_name;
  /**
   * Parse the given string and returns a NameAddrHeader instance or null if
   * it is an invalid NameAddrHeader.
   */
  static dynamic parse(String name_addr_header) {
    // First try manual parsing to bypass grammar parser issues with numeric-starting domains
    try {
      return _manualParse(name_addr_header);
    } catch (e) {
      // Fall back to grammar parser if manual parsing fails
      dynamic parsed = Grammar.parse(name_addr_header, 'Name_Addr_Header');
      if (parsed != -1) {
        return parsed;
      } else {
        return null;
      }
    }
  }

  /**
   * Manual parser for NameAddr format to bypass grammar parser limitations
   * Handles: [display_name] <uri> [;param=value]
   */
  static dynamic _manualParse(String input) {
    String trimmed = input.trim();

    // Extract URI between < and >
    int uriStart = trimmed.indexOf('<');
    int uriEnd = trimmed.indexOf('>');

    if (uriStart == -1 || uriEnd == -1 || uriEnd < uriStart) {
      throw FormatException('Invalid NameAddr format: missing < or >');
    }

    // Extract display name (everything before <)
    String? displayName;
    if (uriStart > 0) {
      displayName = trimmed.substring(0, uriStart).trim();
      // Remove quotes if present
      if (displayName.startsWith('"') && displayName.endsWith('"')) {
        displayName = displayName.substring(1, displayName.length - 1);
      }
      if (displayName.isEmpty) displayName = null;
    }

    // Extract URI string
    String uriString = trimmed.substring(uriStart + 1, uriEnd);

    // Extract parameters (everything after >)
    Map<String, dynamic> parameters = <String, dynamic>{};
    if (uriEnd + 1 < trimmed.length) {
      String paramsString = trimmed.substring(uriEnd + 1);
      List<String> params = paramsString.split(';');
      for (String param in params) {
        param = param.trim();
        if (param.isEmpty) continue;

        int eqIndex = param.indexOf('=');
        if (eqIndex != -1) {
          String key = param.substring(0, eqIndex).trim();
          String value = param.substring(eqIndex + 1).trim();
          // Remove quotes from value if present
          if (value.startsWith('"') && value.endsWith('"')) {
            value = value.substring(1, value.length - 1);
          }
          parameters[key] = value;
        } else {
          parameters[param] = null;
        }
      }
    }

    // Parse URI - try URI.parse first, fall back to manual construction
    URI? uri;
    try {
      uri = URI.parse(uriString);
    } catch (e) {
      // Manual URI parsing for numeric-starting domains
      if (uriString.startsWith('sip:') || uriString.startsWith('sips:')) {
        RegExp uriRegex =
            RegExp(r'^(sips?):([^@]+)@(.+)$', caseSensitive: false);
        Match? match = uriRegex.firstMatch(uriString);
        if (match != null) {
          String scheme = match.group(1)!;
          String user = match.group(2)!;
          String host = match.group(3)!;
          uri = URI(scheme, user, host, null, null, null);
        } else {
          throw FormatException('Invalid SIP URI format: $uriString');
        }
      } else {
        throw FormatException('Unsupported URI scheme in: $uriString');
      }
    }

    if (uri == null) {
      throw FormatException('Failed to parse URI: $uriString');
    }

    // Create and return NameAddrHeader
    return NameAddrHeader(uri, displayName, parameters);
  }

  URI? get uri => _uri;

  String? get display_name => _display_name;

  set display_name(dynamic value) {
    _display_name = (value == 0) ? '0' : value;
  }

  void setParam(String? key, dynamic value) {
    if (key != null) {
      _parameters![key.toLowerCase()] =
          (value == null) ? null : value.toString();
    }
  }

  dynamic getParam(String key) {
    if (key != null) {
      return _parameters![key.toLowerCase()];
    }
  }

  bool hasParam(String key) {
    if (key != null) {
      return _parameters!.containsKey(key.toLowerCase());
    }
    return false;
  }

  dynamic deleteParam(String parameter) {
    parameter = parameter.toLowerCase();
    if (_parameters![parameter] != null) {
      dynamic value = _parameters![parameter];
      _parameters!.remove(parameter);
      return value;
    }
  }

  void clearParams() {
    _parameters = <dynamic, dynamic>{};
  }

  NameAddrHeader clone() {
    return NameAddrHeader(_uri!.clone(), _display_name,
        decoder.convert(encoder.convert(_parameters)));
  }

  String _quote(String str) {
    return str.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  }

  @override
  String toString() {
    String body = (_display_name != null && _display_name!.isNotEmpty)
        ? '"${_quote(_display_name!)}" '
        : '';

    body += '<${_uri.toString()}>';

    _parameters!.forEach((dynamic key, dynamic value) {
      if (_parameters!.containsKey(key)) {
        body += ';$key';
        if (value != null) {
          body += '=$value';
        }
      }
    });

    return body;
  }
}
