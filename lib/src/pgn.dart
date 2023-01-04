import 'dart:math';

import 'package:meta/meta.dart';
import './setup.dart';
import './models.dart';
import './position.dart';
import './utils.dart';

typedef Headers = Map<String, String>;

/// A Node containing PGN data for a move
class PgnNodeData {
  /// SAN representation of the move
  final String san;

  /// Starting comments of the node
  List<String>? startingComments;

  /// Comments about the node
  List<String>? comments;

  /// Numeric Annotation Glyphs for the move
  List<int>? nags;

  /// Constructor for the class
  PgnNodeData(
      {required this.san, this.startingComments, this.comments, this.nags});
}

/// Parent Node containing list of child nodes (Does not contain any data)
class Node<T> {
  List<ChildNode<T>> children = [];
  Node();

  /// Implements a Iterable for the node and its children
  ///
  /// Used for only steping throw the main line
  Iterable<T> mainline() sync* {
    var node = this;
    while (node.children.isNotEmpty) {
      final child = node.children[0];
      yield child.data;
      node = child;
    }
  }
}

/// Child Node which contains data
class ChildNode<T> extends Node<T> {
  T data;
  ChildNode(this.data);
}

/// A game represented by headers and moves derived from a PGN
@immutable
class Game<T> {
  /// Headers of the game
  final Headers headers;

  /// Inital comments of the game
  final List<String> comments;

  /// Parant node containing the game
  final Node<T> moves;

  /// Constant contructor of the class.
  ///
  /// Returns a new immutable Game
  const Game(
      {required this.headers, required this.moves, required this.comments});
}

/// A frame used for parsing a line
class _ParserFrame {
  Node<PgnNodeData> parent;
  bool root;
  ChildNode<PgnNodeData>? node;
  List<String>? startingComments;

  _ParserFrame({required this.parent, required this.root});
}

enum ParserState { bom, pre, headers, moves, comment }

enum PgnState { pre, sidelines, end }

/// A frame used for creating PGN
class _PgnFrame {
  PgnState state;
  int ply;
  ChildNode<PgnNodeData> node;
  Iterator<ChildNode<PgnNodeData>> sidelines;
  bool startsVariation;
  bool inVariation;

  _PgnFrame(
      {required this.state,
      required this.ply,
      required this.node,
      required this.sidelines,
      required this.startsVariation,
      required this.inVariation});
}

/// Defualt headers of a PGN
Headers defaultHeaders() => {
      'Event': '?',
      'Site': '?',
      'Date': '????.??.??',
      'Round': '?',
      'White': '?',
      'Black': '?',
      'Result': '*'
    };

String escapeHeader(String value) =>
    value.replaceAll(RegExp(r'\\'), "\\\\").replaceAll(RegExp('"'), '\\"');
String safeComment(String value) => value.replaceAll(RegExp(r'\}'), '');

int getPlyFromSetup(String fen) {
  try {
    final setup = Setup.parseFen(fen);
    return (setup.fullmoves - 1) * 2 + (setup.turn == Side.white ? 0 : 1);
  } catch (e) {
    return 0;
  }
}

/// Create String out of [Outcome]
String makeOutcome(Outcome? outcome) {
  if (outcome == null) {
    return '*';
  } else if (outcome.winner == Side.white) {
    return '1-0';
  } else if (outcome.winner == Side.black) {
    return '0-1';
  } else {
    return '1/2-1/2';
  }
}

/// Create [Outcome] from string
Outcome? parseOutcome(String? outcome) {
  if (outcome == '1/2-1/2') {
    return Outcome.draw;
  } else if (outcome == '1-0') {
    return Outcome.whiteWins;
  } else if (outcome == '0-1') {
    return Outcome.blackWins;
  } else {
    return null;
  }
}

/// Create a PGN String from [Game]
String makePgn(Game<PgnNodeData> game) {
  final List<String> builder = [];
  final List<String> token = [];

  if (game.headers.isNotEmpty) {
    game.headers.forEach((key, value) {
      builder.add('[$key "${escapeHeader(value)}"]\n');
    });
    builder.add('\n');
  }

  for (final comment in game.comments) {
    builder.add('{ ${safeComment(comment)} }');
  }

  final fen = game.headers['FEN'];
  final initialPly = fen != null ? getPlyFromSetup(fen) : 0;

  final List<_PgnFrame> stack = [];

  if (game.moves.children.isNotEmpty) {
    final variations = game.moves.children.iterator;
    variations.moveNext();
    stack.add(_PgnFrame(
        state: PgnState.pre,
        ply: initialPly,
        node: variations.current,
        sidelines: variations,
        startsVariation: false,
        inVariation: false));
  }

  var forceMoveNumber = true;
  while (stack.isNotEmpty) {
    final frame = stack[stack.length - 1];

    if (frame.inVariation) {
      token.add(')');
      frame.inVariation = false;
      forceMoveNumber = true;
    }

    switch (frame.state) {
      case PgnState.pre:
        {
          if (frame.node.data.startingComments != null) {
            for (final comment in frame.node.data.startingComments!) {
              token.add('{ ${safeComment(comment)} }');
            }
            forceMoveNumber = true;
          }
          if (forceMoveNumber || frame.ply.isEven) {
            token.add(
                '${(frame.ply / 2).floor() + 1}${frame.ply.isOdd ? "..." : "."}');
            forceMoveNumber = false;
          }
          token.add(frame.node.data.san);
          if (frame.node.data.nags != null) {
            for (final nag in frame.node.data.nags!) {
              token.add('\$$nag');
            }
            forceMoveNumber = true;
          }
          if (frame.node.data.comments != null) {
            for (final comment in frame.node.data.comments!) {
              token.add('{ ${safeComment(comment)} }');
            }
          }
          frame.state = PgnState.sidelines;
          continue;
        }

      case PgnState.sidelines:
        {
          final child = frame.sidelines.moveNext();
          if (child) {
            token.add('(');
            forceMoveNumber = true;
            stack.add(_PgnFrame(
                state: PgnState.pre,
                ply: frame.ply,
                node: frame.sidelines.current,
                sidelines:
                    <ChildNode<PgnNodeData>>[].iterator, // empty iterator
                startsVariation: true,
                inVariation: false));
            frame.inVariation = true;
          } else {
            if (frame.node.children.isNotEmpty) {
              final variations = frame.node.children.iterator;
              variations.moveNext();
              stack.add(_PgnFrame(
                  state: PgnState.pre,
                  ply: frame.ply + 1,
                  node: variations.current,
                  sidelines: variations,
                  startsVariation: false,
                  inVariation: false));
            }
            frame.state = PgnState.end;
          }
          break;
        }

      case PgnState.end:
        {
          stack.removeLast();
        }
    }
  }
  token.add(makeOutcome(parseOutcome(game.headers['Result'])));
  builder.add('${token.join(" ")}\n');
  return builder.join();
}

const bom = '\ufeff';

Headers emptyHeaders() {
  return <String, String>{};
}

bool isWhitespace(String line) => RegExp(r'^\s*$').hasMatch(line);

bool isCommentLine(String line) => line.startsWith('%');

class PgnError implements Exception {
  final String message;
  PgnError(this.message);
}

/// A class to read a string and create a [Game]
///
/// Also supports parsing via a stream configured with a budget and yields games when completed
/// Set budget to null when not streaming
class PgnParser {
  List<String> _lineBuf = [];
  int? _budget;
  late bool _found;
  late ParserState _state = ParserState.pre;
  late Headers _gameHeaders;
  late List<String> _gameComments;
  late Node<PgnNodeData> _gameMoves;
  late List<_ParserFrame> _stack;
  late List<String> _commentBuf;
  int? maxBudget;

  final void Function(Game<PgnNodeData>, [Error?]) emitGame;
  final Headers Function() initHeaders;

  PgnParser(this.emitGame, this.initHeaders, [this.maxBudget = 1000000]) {
    resetGame();
    _state = ParserState.bom;
  }

  void resetGame() {
    _budget = maxBudget;
    _found = false;
    _state = ParserState.pre;
    _gameHeaders = initHeaders();
    _gameMoves = Node();
    _gameComments = [];
    _commentBuf = [];
    _stack = [_ParserFrame(parent: _gameMoves, root: true)];
  }

  void _consumeBudget(int cost) {
    if (_budget == null) return;
    _budget = _budget! - cost;
    if (_budget! < 0) {
      throw PgnError('ERR_PGN_BUDGET');
    }
  }

  void _emit(Error? err) {
    if (_state == ParserState.comment) {
      _handleComment();
    }
    if (err != null) {
      return emitGame(
          Game(
              headers: _gameHeaders,
              moves: _gameMoves,
              comments: _gameComments),
          err);
    }
    if (_found) {
      emitGame(
          Game(
              headers: _gameHeaders,
              moves: _gameMoves,
              comments: _gameComments),
          null);
    }
    resetGame();
  }

  /// Parse the PGN string
  void parse(String data, {bool? stream}) {
    if (_budget != null && _budget! < 0) return;
    try {
      var idx = 0;
      for (;;) {
        final nlIdx = data.indexOf('\n', idx);
        if (nlIdx == -1) {
          break;
        }
        final crIdx =
            nlIdx > idx && data[nlIdx - 1] == '\r' ? nlIdx - 1 : nlIdx;
        _consumeBudget(nlIdx - idx);
        _lineBuf.add(data.substring(idx, crIdx));
        idx = nlIdx + 1;
        _handleLine();
      }
      _consumeBudget(data.length - idx);
      _lineBuf.add(data.substring(idx));

      if (stream == null) {
        _handleLine();
        _emit(null);
      }
    } catch (err) {
      _emit(err as Error);
    }
  }

  void _handleLine() {
    var freshLine = true;
    var line = _lineBuf.join();
    _lineBuf = [];
    continuedLine:
    for (;;) {
      switch (_state) {
        case ParserState.bom:
          {
            if (line.startsWith(bom)) {
              line = line.substring(bom.length);
            }
            _state = ParserState.pre;
            continue;
          }

        case ParserState.pre:
          {
            if (isWhitespace(line) || isCommentLine(line)) return;
            _found = true;
            _state = ParserState.headers;
            continue;
          }

        case ParserState.headers:
          {
            if (isCommentLine(line)) return;
            var moreHeaders = true;
            final headerReg = RegExp(
                r'^\s*\[([A-Za-z0-9][A-Za-z0-9_+#=:-]*)\s+"((?:[^"\\]|\\"|\\\\)*)"\]');
            while (moreHeaders) {
              moreHeaders = false;
              line = line.replaceFirstMapped(headerReg, (match) {
                _consumeBudget(200);
                _gameHeaders[match[1]!] =
                    match[2]!.replaceAll(r'\\"', '"').replaceAll(r'\\\\', '\\');
                moreHeaders = true;
                freshLine = false;
                return '';
              });
            }
            if (isWhitespace(line)) return;
            _state = ParserState.moves;
            continue;
          }

        case ParserState.moves:
          {
            if (freshLine) {
              if (isCommentLine(line)) return;
              if (isWhitespace(line)) return _emit(null);
            }
            final tokenRegex = RegExp(
                r'(?:[NBKRQ]?[a-h]?[1-8]?[-x]?[a-h][1-8](?:=?[nbrqkNBRQK])?|[pnbrqkPNBRQK]?@[a-h][1-8]|O-O-O|0-0-0|O-O|0-0)[+#]?|--|Z0|0000|@@@@|{|;|\$\d{1,4}|[?!]{1,2}|\(|\)|\*|1-0|0-1|1\/2-1\/2/');
            final matches = tokenRegex.allMatches(line);
            for (final match in matches) {
              final frame = _stack[_stack.length - 1];
              var token = match[0]!;
              if (token == ';') {
                return;
              } else if (token.startsWith('\$')) {
                _handleNag(int.parse(token.substring(1)));
              } else if (token == '!') {
                _handleNag(1);
              } else if (token == '?') {
                _handleNag(2);
              } else if (token == '!!') {
                _handleNag(3);
              } else if (token == '??') {
                _handleNag(4);
              } else if (token == '!?') {
                _handleNag(5);
              } else if (token == '?!') {
                _handleNag(6);
              } else if (token == '1-0' ||
                  token == '0-1' ||
                  token == '1/2-1/2' ||
                  token == '*') {
                if (_stack.length == 1 && token != '*') {
                  _gameHeaders['Result'] = token;
                }
              } else if (token == '(') {
                _consumeBudget(100);
                _stack.add(_ParserFrame(parent: frame.parent, root: false));
              } else if (token == ')') {
                if (_stack.length > 1) _stack.removeLast();
              } else if (token == '{') {
                final openIndex = match.end;
                final beginIndex =
                    line[openIndex] == ' ' ? openIndex + 1 : openIndex;
                line = line.substring(beginIndex);
                _state = ParserState.comment;
                continue continuedLine;
              } else {
                _consumeBudget(100);
                if (token == 'Z0' || token == '0000' || token == '@@@@') {
                  token = '--';
                } else if (token.startsWith('0')) {
                  token = token.replaceAll('0', 'O');
                }
                if (frame.node != null) {
                  frame.parent = frame.node!;
                }
                frame.node = ChildNode(PgnNodeData(
                    san: token, startingComments: frame.startingComments));
                frame.startingComments = null;
                frame.root = false;
                frame.parent.children.add(frame.node!);
              }
            }
            return;
          }

        case ParserState.comment:
          {
            final closeIndex = line.indexOf('}');
            if (closeIndex == -1) {
              _commentBuf.add(line);
              return;
            } else {
              final endIndex = closeIndex > 0 && line[closeIndex - 1] == ' '
                  ? closeIndex - 1
                  : closeIndex;
              _commentBuf.add(line.substring(0, endIndex));
              _handleComment();
              line = line.substring(closeIndex);
              _state = ParserState.moves;
              freshLine = false;
            }
          }
      }
    }
  }

  void _handleNag(int nag) {
    _consumeBudget(50);
    final frame = _stack[_stack.length - 1];
    if (frame.node != null) {
      frame.node!.data.nags ??= [];
      frame.node!.data.nags!.add(nag);
    }
  }

  void _handleComment() {
    _consumeBudget(100);
    final frame = _stack[_stack.length - 1];
    final comment = _commentBuf.join('\n');
    _commentBuf = [];
    if (frame.node != null) {
      frame.node!.data.comments ??= [];
      frame.node!.data.comments!.add(comment);
    } else if (frame.root) {
      _gameComments.add(comment);
    } else {
      frame.startingComments ??= [];
      frame.startingComments!.add(comment);
    }
  }
}

/// Default function to parse a PGN
///
/// Creates a list of games if multiple games found
List<Game<PgnNodeData>> parsePgn(String pgn,
    [Headers Function() initHeaders = defaultHeaders]) {
  final List<Game<PgnNodeData>> games = [];
  PgnParser((Game<PgnNodeData> game, [Error? err]) => games.add(game),
          initHeaders, null)
      .parse(pgn);
  return games;
}

Variant? parseVariant(String variant) {
  switch (variant.toLowerCase()) {
    case 'chess':
    case 'chess960':
    case 'chess 960':
    case 'standard':
    case 'from position':
    case 'classical':
    case 'normal':
    case 'fischerandom': // Cute Chess
    case 'fischerrandom':
    case 'fischer random':
    case 'wild/0':
    case 'wild/1':
    case 'wild/2':
    case 'wild/3':
    case 'wild/4':
    case 'wild/5':
    case 'wild/6':
    case 'wild/7':
    case 'wild/8':
    case 'wild/8a':
      return Variant.chess;
    case 'crazyhouse':
    case 'crazy house':
    case 'house':
    case 'zh':
      return Variant.crazyhouse;
    case 'king of the hill':
    case 'koth':
    case 'kingofthehill':
      return Variant.kingofthehill;
    case 'three-check':
    case 'three check':
    case 'threecheck':
    case 'three check chess':
    case '3-check':
    case '3 check':
    case '3check':
      return Variant.threecheck;
    case 'antichess':
    case 'anti chess':
    case 'anti':
      return Variant.antichess;
    case 'atomic':
    case 'atom':
    case 'atomic chess':
      return Variant.atomic;
    case 'horde':
    case 'horde chess':
      return Variant.horde;
    case 'racing kings':
    case 'racingkings':
    case 'racing':
    case 'race':
      return Variant.racingKings;
    default:
      return null;
  }
}

/// Create a [Position] from setup and variants
Position setupPosition(Variant rules, Setup setup, bool ignoreCheck) {
// missing horde, racingkings. Returns Chess for those variants
  switch (rules) {
    case Variant.chess:
      return Chess.fromSetup(setup, ignoreImpossibleCheck: ignoreCheck);
    case Variant.antichess:
      return Antichess.fromSetup(setup, ignoreImpossibleCheck: ignoreCheck);
    case Variant.atomic:
      return Atomic.fromSetup(setup, ignoreImpossibleCheck: ignoreCheck);
    case Variant.kingofthehill:
      return KingOfTheHill.fromSetup(setup, ignoreImpossibleCheck: ignoreCheck);
    case Variant.crazyhouse:
      return Crazyhouse.fromSetup(setup, ignoreImpossibleCheck: ignoreCheck);
    case Variant.threecheck:
      return ThreeCheck.fromSetup(setup, ignoreImpossibleCheck: ignoreCheck);
    default:
      return Chess.fromSetup(setup, ignoreImpossibleCheck: ignoreCheck);
  }
}

/// Create a [Position] for a Variant from the headers
///
/// Headers must include a 'Variant' and 'Fen' key
Position startingPosition(Headers headers, bool ignoreCheck) {
  if (!headers.containsKey('Variant')) throw PgnError('ERR_HEADER_NO_VARIANT');
  final rules = parseVariant(headers['Variant']!);
  if (rules == null) throw PgnError('ERR_HEADER_INVALID_VARIANT');
  if (!headers.containsKey('FEN')) throw PgnError('ERR_HEADER_NO_FEN');
  final fen = headers['FEN']!;
  try {
    return setupPosition(rules, Setup.parseFen(fen), ignoreCheck);
  } catch (err) {
    rethrow;
  }
}

/// Returns the defualt [Position] for the [Variant]
Position defualtPosition(Variant variant) {
  switch (variant) {
    case Variant.chess:
      return Chess.initial;
    case Variant.antichess:
      return Antichess.initial;
    case Variant.atomic:
      return Atomic.initial;
    case Variant.kingofthehill:
      return KingOfTheHill.initial;
    case Variant.threecheck:
      return ThreeCheck.initial;
    case Variant.crazyhouse:
      return Crazyhouse.initial;
    case Variant.horde:
      return Chess.initial;
    default:
      return Chess.initial;
  }
}

/// Set the [Variant] and the 'Fen' for the headers
void setStartingPosition(Headers headers, Position pos) {
  final variant = pos.variant;
  if (variant != Variant.chess) {
    headers['Variant'] = variant.string!;
  } else {
    headers.remove('Variant');
  }

  final defaultFen = defualtPosition(pos.variant).fen;
  if (pos.fen != defaultFen) {
    headers['FEN'] = pos.fen;
  } else {
    headers.remove('FEN');
  }
}

enum CommentShapeColor {
  green,
  red,
  yellow,
  blue;

  String get string {
    switch (this) {
      case CommentShapeColor.green:
        return 'green';
      case CommentShapeColor.red:
        return 'red';
      case CommentShapeColor.yellow:
        return 'yellow';
      case CommentShapeColor.blue:
        return 'blue';
    }
  }

  static CommentShapeColor? parseShapeColor(String str) {
    switch (str) {
      case 'G':
        return CommentShapeColor.green;
      case 'R':
        return CommentShapeColor.red;
      case 'Y':
        return CommentShapeColor.yellow;
      case 'B':
        return CommentShapeColor.blue;
      default:
        return null;
    }
  }
}

class CommentShape {
  CommentShapeColor color;
  Square from;
  Square to;

  CommentShape({required this.color, required this.from, required this.to});
}

enum EvalType { pawns, mate }

/// A class containing an evaluation
/// A Evaluation object can be created used .pawns or .mate contructor
@immutable
class Evaluation {
  final double? pawns;
  final int? mate;
  final int? depth;
  final EvalType evalType;

  const Evaluation.pawns(
      {required this.pawns,
      this.evalType = EvalType.pawns,
      this.depth,
      this.mate});
  const Evaluation.mate(
      {required this.mate,
      this.evalType = EvalType.mate,
      this.depth,
      this.pawns});

  bool isPawns() => evalType == EvalType.pawns;
}

@immutable
class Comment {
  final String? text;
  final List<CommentShape>? shapes;
  final double? clock;
  final double? emt;
  final Evaluation? eval;

  const Comment({this.text, this.shapes, this.clock, this.emt, this.eval});
}

String makeClk(double seconds) {
  var maxSec = max(0, seconds);
  final hours = (maxSec / 3600).floor();
  final minutes = ((maxSec % 3600) / 60).floor();
  maxSec = (maxSec % 3600) % 60;
  return '$hours:${minutes.toString().padLeft(2, "0")}:${seconds.toStringAsFixed(3).padLeft(5, "0")}';
}

String makeCommentShape(CommentShape shape) => shape.to == shape.from
    ? '${shape.color.string[0]}${toAlgebraic(shape.to)}'
    : '${shape.color.string[0]}${toAlgebraic(shape.from)}${toAlgebraic(shape.to)}';

CommentShape? parseCommentShape(String str) {
  final color = CommentShapeColor.parseShapeColor(str.substring(0, 1));
  final from = parseSquare(str.substring(1, 3));
  final to = parseSquare(str.substring(3, 5));
  if (color == null || from == null) return null;
  if (str.length == 3) return CommentShape(color: color, from: from, to: from);
  if (str.length == 5 && to != null) {
    return CommentShape(color: color, from: from, to: to);
  }
  return null;
}

String makeEval(Evaluation ev) {
  var str = '';
  if (ev.isPawns()) {
    str = ev.pawns!.toStringAsFixed(2);
  } else {
    str = '${ev.mate}';
  }
  if (ev.depth != null) str = '$str,${ev.depth}';
  return str;
}

String makeComment(Comment comment) {
  final List<String> builder = [];
  if (comment.text != null) builder.add(comment.text!);
  if (comment.shapes != null) {
    final circles = comment.shapes!
        .where((shape) => shape.to == shape.from)
        .map(makeCommentShape);
    if (circles.isNotEmpty) builder.add('[%csl ${circles.join(",")}]');
    final arrows = comment.shapes!
        .where((shape) => shape.to != shape.from)
        .map(makeCommentShape);
    if (arrows.isNotEmpty) builder.add('[%cal ${arrows.join(",")}]');
  }
  if (comment.eval != null) builder.add('[%eval ${makeEval(comment.eval!)}]');
  if (comment.emt != null) builder.add('[%emt ${makeClk(comment.emt!)}]');
  if (comment.clock != null) builder.add('[%emt ${makeClk(comment.clock!)}]');
  return builder.join(' ');
}

Comment parseComment(String comment) {
  double? emt;
  double? clock;
  final List<CommentShape> shapes = [];
  Evaluation? eval;
  var text = comment.replaceAllMapped(
      RegExp(
          r'\s?\[%(emt|clk)\s(\d{1,5}):(\d{1,2}):(\d{1,2}(?:\.\d{0,3})?)\]\s?'),
      (match) {
    final annotation = match.group(1);
    final hours = match.group(2);
    final minutes = match.group(3);
    final seconds = match.group(4);
    final value = int.parse(hours!) * 3600 +
        int.parse(minutes!) * 60 +
        double.parse(seconds!);
    if (annotation == 'emt') {
      emt = value;
    } else if (annotation == 'clk') {
      clock = value;
    }
    return ' ';
  }).replaceAllMapped(
      RegExp(
          r'\s?\[%(?:csl|cal)\s([RGYB][a-h][1-8](?:[a-h][1-8])?(?:,[RGYB][a-h][1-8](?:[a-h][1-8])?)*)\]\s?'),
      (match) {
    final arrows = match.group(1);
    for (final arrow in arrows!.split(',')) {
      var shape = parseCommentShape(arrow);
      if (shape != null) shapes.add(shape);
    }
    return '  ';
  }).replaceAllMapped(
      RegExp(
          r'\s?\[%eval\s(?:#([+-]?\d{1,5})|([+-]?(?:\d{1,5}|\d{0,5}\.\d{1,2})))(?:,(\d{1,5}))?\]\s?'),
      (match) {
    final mate = match.group(1);
    final pawns = match.group(2);
    final d = match.group(3);
    final depth = d != null ? int.parse(d) : null;
    eval = mate != null
        ? Evaluation.mate(mate: int.parse(mate))
        : Evaluation.pawns(pawns: double.parse(pawns!), depth: depth);
    return '  ';
  }).trim();

  return Comment(
      text: text, shapes: shapes, emt: emt, clock: clock, eval: eval);
}
