import 'dart:convert' show utf8;

import 'constants.dart' as DartSIP_C;
import 'data.dart';
import 'grammar.dart';
import 'logger.dart';
import 'sip_message.dart';
import 'ua.dart';
import 'uri.dart';

dynamic _parseRequestLine(String line) {
  // Match: METHOD uri SIP/2.0
  RegExp requestRegex = RegExp(r'^([A-Z]+)\s+(.+)\s+SIP/2\.0$');
  Match? match = requestRegex.firstMatch(line);

  if (match == null) {
    logger.d('_parseRequestLine: regex did not match line: $line');
    return null;
  }

  String methodString = match.group(1)!;
  String uriString = match.group(2)!;

  logger.d('_parseRequestLine: method=$methodString, uri=$uriString');

  // Parse the URI - handle both sip: and sips: schemes
  URI? uri;

  // First try to extract the basic URI structure manually
  if (uriString.startsWith('sip:') || uriString.startsWith('sips:')) {
    try {
      // Extract scheme
      int schemeEnd = uriString.indexOf(':');
      String scheme = uriString.substring(0, schemeEnd);
      String rest = uriString.substring(schemeEnd + 1);

      // Parse user@host;params format
      String? user;
      String host;
      int? port;
      Map<String, dynamic> params = <String, dynamic>{};

      // Split on @ to get user part (if present)
      int atIndex = rest.indexOf('@');
      if (atIndex != -1) {
        user = rest.substring(0, atIndex);
        rest = rest.substring(atIndex + 1);
      }

      // Split on ; to separate host from parameters
      int semicolonIndex = rest.indexOf(';');
      String hostPart;
      String? paramsPart;

      if (semicolonIndex != -1) {
        hostPart = rest.substring(0, semicolonIndex);
        paramsPart = rest.substring(semicolonIndex + 1);
      } else {
        hostPart = rest;
      }

      // Check for port in host part
      int colonIndex = hostPart.lastIndexOf(':');
      if (colonIndex != -1 && !hostPart.contains('[')) {
        // Not IPv6, could be port
        String potentialPort = hostPart.substring(colonIndex + 1);
        if (int.tryParse(potentialPort) != null) {
          host = hostPart.substring(0, colonIndex);
          port = int.parse(potentialPort);
        } else {
          host = hostPart;
        }
      } else {
        host = hostPart;
      }

      // Parse parameters
      if (paramsPart != null) {
        List<String> paramsList = paramsPart.split(';');
        for (String param in paramsList) {
          int eqIndex = param.indexOf('=');
          if (eqIndex != -1) {
            String key = param.substring(0, eqIndex);
            String value = param.substring(eqIndex + 1);
            params[key] = value;
          } else {
            params[param] = null;
          }
        }
      }

      // Create URI object
      uri = URI(scheme, user, host, port, params, null);

      logger.d(
          '_parseRequestLine: successfully parsed URI - scheme=$scheme, user=$user, host=$host, port=$port');

      // Create ParsedData object to match grammar parser output
      ParsedData data = ParsedData();
      data.method_str = methodString;
      data.uri = uri;
      data.status_code = null;

      logger.d(
          '_parseRequestLine: ✅ MANUAL PARSER returning ParsedData - method_str=${data.method_str}, uri=${data.uri}, uri.scheme=${uri.scheme}, uri.user=${uri.user}, uri.host=${uri.host}, method_enum=${data.method}');

      return data;
    } catch (e) {
      // If manual parsing fails, return null to trigger fallback
      logger.e('_parseRequestLine: exception during parsing: $e');
      return null;
    }
  }

  logger.d('_parseRequestLine: URI scheme not sip/sips, returning null');
  return null;
}

dynamic _parseResponseLine(String line) {
  // Match: SIP/2.0 status_code reason_phrase
  RegExp responseRegex = RegExp(r'^SIP/2\.0\s+(\d{3})\s*(.*)$');
  Match? match = responseRegex.firstMatch(line);

  if (match == null) {
    return null;
  }

  int statusCode = int.parse(match.group(1)!);
  String reasonPhrase = match.group(2)?.trim() ?? '';

  // Create ParsedData object to match grammar parser output
  ParsedData data = ParsedData();
  data.status_code = statusCode;
  data.reason_phrase = reasonPhrase;

  logger.d('_parseResponseLine: ✅ MANUAL PARSER returning ParsedData - status_code=$statusCode, reason_phrase=$reasonPhrase');

  return data;
}

/**
 * Parse SIP Message
 */
IncomingMessage? parseMessage(String data, UA? ua) {
  IncomingMessage message;
  int bodyStart;
  int headerEnd = data.indexOf('\r\n');

  if (headerEnd == -1) {
    logger.e('parseMessage() | no CRLF found, not a SIP message');
    return null;
  }

  // Parse first line. Check if it is a Request or a Reply.
  String firstLine = data.substring(0, headerEnd);
  dynamic parsed;

  logger.d('parseMessage: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  logger.d('parseMessage: 📨 PARSING FIRST LINE: $firstLine');
  logger.d('parseMessage: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

  // Try grammar parser FIRST (original behavior)
  try {
    parsed = Grammar.parse(firstLine, 'Request_Response');
    logger.d('parseMessage: ✅ GRAMMAR PARSER succeeded');
  } catch (FormatException) {
    logger.d('parseMessage: ❌ GRAMMAR PARSER failed, trying manual parsers for numeric-starting domains');

    // Fall back to manual parsing for numeric-starting domains
    if (firstLine.startsWith('SIP/2.0')) {
      // It's a response
      logger.d('parseMessage: using manual response parser');
      parsed = _parseResponseLine(firstLine);
    } else {
      // It's a request
      logger.d('parseMessage: using manual request parser');
      parsed = _parseRequestLine(firstLine);
    }

    // If manual parsing also failed, set to -1
    if (parsed == null) {
      logger.e('parseMessage: both grammar and manual parsers failed');
      parsed = -1;
    } else {
      logger.d('parseMessage: manual parsing succeeded');
    }
  }

  if (parsed == null || parsed == -1) {
    logger.e(
        'parseMessage() | error parsing first line of SIP message: "$firstLine"');

    return null;
  } else if (parsed.status_code == null) {
    // This is a REQUEST
    logger.d('parseMessage: Creating IncomingRequest - method_str=${parsed.method_str}, uri=${parsed.uri}');
    IncomingRequest incomingRequest = IncomingRequest(ua);
    incomingRequest.method = parsed.method;
    incomingRequest.ruri = parsed.uri;
    logger.d('parseMessage: IncomingRequest created - method=${incomingRequest.method}, ruri=${incomingRequest.ruri}');
    message = incomingRequest;
  } else {
    // This is a RESPONSE
    logger.d('parseMessage: Creating IncomingResponse - status_code=${parsed.status_code}, reason=${parsed.reason_phrase}');
    message = IncomingResponse();
    message.status_code = parsed.status_code;
    message.reason_phrase = parsed.reason_phrase;
  }

  message.data = data;
  int headerStart = headerEnd + 2;

  /* Loop over every line in data. Detect the end of each header and parse
  * it or simply add to the headers collection.
  */
  while (true) {
    headerEnd = getHeader(data, headerStart);

    // The SIP message has normally finished.
    if (headerEnd == -2) {
      bodyStart = headerStart + 2;
      break;
    }
    // Data.indexOf returned -1 due to a malformed message.
    else if (headerEnd == -1) {
      logger.e('parseMessage() | malformed message');

      return null;
    }

    parsed = parseHeader(message, data, headerStart, headerEnd);

    if (parsed != true) {
      logger.e('parseMessage() |${parsed['error']}');
      return null;
    }

    headerStart = headerEnd + 2;
  }

  /* RFC3261 18.3.
   * If there are additional bytes in the transport packet
   * beyond the end of the body, they MUST be discarded.
   */
  if (message.hasHeader('content-length')) {
    dynamic headerContentLength = message.getHeader('content-length');

    if (headerContentLength is String) {
      headerContentLength = int.tryParse(headerContentLength) ?? 0;
    }
    headerContentLength ??= 0;

    if (headerContentLength > 0) {
      List<int> actualContent = utf8.encode(data.substring(bodyStart));
      if (headerContentLength != actualContent.length)
        logger.w(
            '${message.method} received with content-length: $headerContentLength but actual length is: ${actualContent.length}');
      List<int> encodedBody = utf8.encode(data.substring(bodyStart));
      List<int> content = encodedBody.sublist(0, actualContent.length);
      message.body = utf8.decode(content);
    }
  } else {
    message.body = data.substring(bodyStart);
  }

  // Log final parsed message details for debugging
  if (message is IncomingRequest) {
    logger.d('parseMessage: ✅ Final IncomingRequest - method=${message.method}, ruri=${message.ruri}, call_id=${message.call_id}, from=${message.from}, to=${message.to}');
  } else if (message is IncomingResponse) {
    logger.d('parseMessage: ✅ Final IncomingResponse - status=${message.status_code}, reason=${message.reason_phrase}, call_id=${message.call_id}, method=${message.method}');
  }

  return message;
}

/**
 * Extract and parse every header of a SIP message.
 */
int getHeader(String data, int headerStart) {
  // 'start' position of the header.
  int start = headerStart;
  // 'end' position of the header.
  int end = 0;
  // 'partial end' position of the header.
  int partialEnd = 0;

  // End of message.
  if (data.substring(start, start + 2).contains(RegExp(r'(^\r\n)'))) {
    return -2;
  }

  while (end == 0) {
    // Partial End of Header.
    partialEnd = data.indexOf('\r\n', start);

    // 'indexOf' returns -1 if the value to be found never occurs.
    if (partialEnd == -1) {
      return partialEnd;
    }
    //if (!data.substring(partialEnd + 2, partialEnd + 4).match(/(^\r\n)/) && data.charAt(partialEnd + 2).match(/(^\s+)/))

    if (!data
            .substring(partialEnd + 2, partialEnd + 4)
            .contains(RegExp(r'(^\r\n)')) &&
        String.fromCharCode(data.codeUnitAt(partialEnd + 2))
            .contains(RegExp(r'(^\s+)'))) {
      // Not the end of the message. Continue from the next position.
      start = partialEnd + 2;
    } else {
      end = partialEnd;
    }
  }

  return end;
}

dynamic parseHeader(
    IncomingMessage message, String data, int headerStart, int headerEnd) {
  dynamic parsed;
  int hcolonIndex = data.indexOf(':', headerStart);
  String headerName = data.substring(headerStart, hcolonIndex).trim();
  String headerValue = data.substring(hcolonIndex + 1, headerEnd).trim();

  // If header-field is well-known, parse it.
  switch (headerName.toLowerCase()) {
    case 'via':
    case 'v':
      message.addHeader('via', headerValue);
      if (message.getHeaders('via').length == 1) {
        parsed = message.parseHeader('Via');
        if (parsed != null) {
          message.via_branch = parsed.branch;
        }
      } else {
        parsed = 0;
      }
      break;
    case 'from':
    case 'f':
      message.setHeader('from', headerValue);
      parsed = message.parseHeader('from');
      if (parsed != null) {
        message.from = parsed;
        message.from_tag = parsed.getParam('tag');
      }
      break;
    case 'to':
    case 't':
      message.setHeader('to', headerValue);
      parsed = message.parseHeader('to');
      if (parsed != null) {
        message.to = parsed;
        message.to_tag = parsed.getParam('tag');
      }
      break;
    case 'record-route':
      parsed = Grammar.parse(headerValue, 'Record_Route');

      if (parsed == -1) {
        parsed = null;
      } else {
        for (Map<String, dynamic> header in parsed) {
          message.addHeader('record-route', header['raw']);
          message.headers!['Record-Route']
                  [message.getHeaders('record-route').length - 1]['parsed'] =
              header['parsed'];
        }
      }
      break;
    case 'call-id':
    case 'i':
      message.setHeader('call-id', headerValue);
      parsed = message.parseHeader('call-id');
      if (parsed != null) {
        message.call_id = headerValue;
      }
      break;
    case 'contact':
    case 'm':
      parsed = Grammar.parse(headerValue, 'Contact');

      if (parsed == -1) {
        parsed = null;
      } else {
        for (Map<String, dynamic> header in parsed) {
          message.addHeader('contact', header['raw']);
          message.headers!['Contact'][message.getHeaders('contact').length - 1]
              ['parsed'] = header['parsed'];
        }
      }
      break;
    case 'content-length':
    case 'l':
      message.setHeader('content-length', headerValue);
      parsed = message.parseHeader('content-length');
      break;
    case 'content-type':
    case 'c':
      message.setHeader('content-type', headerValue);
      parsed = message.parseHeader('content-type');
      break;
    case 'cseq':
      message.setHeader('cseq', headerValue);
      parsed = message.parseHeader('cseq');
      if (parsed != null) {
        message.cseq = parsed.cseq;
      }
      if (message is IncomingResponse) {
        message.method = parsed.method;
      }
      break;
    case 'max-forwards':
      message.setHeader('max-forwards', headerValue);
      parsed = message.parseHeader('max-forwards');
      break;
    case 'www-authenticate':
      message.setHeader('www-authenticate', headerValue);
      parsed = message.parseHeader('www-authenticate');
      break;
    case 'proxy-authenticate':
      message.setHeader('proxy-authenticate', headerValue);
      parsed = message.parseHeader('proxy-authenticate');
      break;
    case 'session-expires':
    case 'x':
      message.setHeader('session-expires', headerValue);
      parsed = message.parseHeader('session-expires');
      if (parsed != null) {
        message.session_expires = parsed.expires;
        message.session_expires_refresher = parsed.refresher;
      }
      break;
    case 'refer-to':
    case 'r':
      message.setHeader('refer-to', headerValue);
      parsed = message.parseHeader('refer-to');
      if (parsed != null) {
        message.refer_to = parsed;
      }
      break;
    case 'replaces':
      message.setHeader('replaces', headerValue);
      parsed = message.parseHeader('replaces');
      if (parsed != null) {
        message.replaces = parsed;
      }
      break;
    case 'event':
    case 'o':
      message.setHeader('event', headerValue);
      parsed = message.parseHeader('event');
      if (parsed != null) {
        message.event = parsed;
      }
      break;
    default:
      // Do not parse this header.
      message.addHeader(headerName, headerValue);
      parsed = 0;
  }

  if (parsed == null) {
    return <String, dynamic>{'error': 'error parsing header "$headerName"'};
  } else {
    return true;
  }
}
