# _Contracts_ in Nix design and implementations details:
#
# * we try, for a better developer experience, to disambiguate with case:
#   - `Types` that takes a value and return a Boolean
#   - `builders` that takes one or several values and return a Type
# * when a function takes a type as argument, always implicitly pass it to the
#   `def` method, `Type` is only made to describe `nixpkgs.lib.types` not to be
#   used with `fn` construct!
#
# n.b. Have a look at the `README.md` for a getting start tutorial!

{ enable ? false, ... }: let

# TODO version = is types.SemVer "0.0.1";

/* Turn arbitrary data into a type (a fancy functor) */
declare = with types; args: type: {
  __functor  = self: self.check;
  __toString = self: self.name;
  check = e:
    if Functor type || Lambda type then type e
    else if Set type then
      builtins.all (n: e?${n} && def type.${n} e.${n})
                   (builtins.attrNames type)
    else if List type then
      builtins.length e >= builtins.length type &&
      builtins.all (n: def (builtins.elemAt type n) (builtins.elemAt e n))
                   (builtins.genList (i: i) (builtins.length type))
    else e == type;
  name =
    if      List  type then  "[ ${builtins.toString type} ]"
    else if Print type then       builtins.toString type
    else if Set   type then ''{ ${builtins.toString (
      map (n: "${n} = ${def type.${n}};") (builtins.attrNames type)
    )} }''
    else "<UNNAMED>";
} // args;

/* Shortcut alias of `declare` function without argument */
def = declare {};

/* If a `value` respect a `type` return the `value` else a `default` value */
default  = d: t: v: if def t v then v else d;

/* If a `value` respect a `type` return the `value` else throw an error */
contract = {
  name ? "<UNNAMED>",
  message ? s: "The following value don't respect the `${s.name}' contract:"
}: type: value:
  if enable then let type' = def type;
    isBool = value: assert types.Bool value || errors.INVALID_TYPE; value;
    errors = {
      INVALID_TYPE = builtins.throw ''
        InvalidType: `${type'}' is not a function that return a `Boolean` ...
        > n.b. Do you forget parenthesis around a type constructor?
      '';
      TYPE_ERROR = builtins.trace (message { inherit name; type = type'; })
                   builtins.trace value builtins.throw ''
        TypeError: `check` function of the type `${type'}' return `false' ...
        > n.b. This error comes from `github:yvan-sraka/contracts' library
      '';
    }; in assert isBool (type' value) || errors.TYPE_ERROR; value
  else value;

/* Shortcut alias of `contract` function with default arguments */
is = contract { message = s: "Value should be of type `${s.type}':"; };

# TODO I'm not sure if this would be really handy:
#     FunctionArgs = args: f: args == builtins.functionArgs f;
# ... because I would prefer something like:
fn = arg: f: x: f (is (def arg) x);

/* Force the concrete evaluation of a contract or any datatype */
strict = e: builtins.deepSeq e e;

#################################### TYPES ####################################
types = rec {

/* *** Top and Bottom types *** */
Any     = e: true;
None    = e: false;

/* *** Primitives types offered by Nix builtins *** */
Set     = builtins.isAttrs;
Bool    = builtins.isBool;
Float   = builtins.isFloat;
Lambda  = builtins.isFunction;
Int     = builtins.isInt;
List    = builtins.isList;
Path    = builtins.isPath;
Str     = builtins.isString;
Null    = e: e == null;
Functor = e: Set e && e?__functor;
# Handy type fillers that throw an error if evaluated:
TODO    = e: throw "Not implemented yet ...";

/* *** Types could be composed into new types *** */
Type    = def { name = Str; check = enum [ Lambda Functor ]; };
# `Format` means "it could be turn into a string", with `"${x}"` syntax ...
Format  = enum [ Str Path (e: Set e && (e?__toString || e?outPath)) ];
# ... and `Print` it could be with `toString x`, any better name idea?
Print   = enum [ Bool Float Format Int List Null ];
# TODO choose types coming from `nixpkgs.lib.types`, e.g.:
# * Package = enum [ lib.isDerivation lib.isStorePath ];
# * NonEmptyStr = Str e && str != "";

/* *** Type builders could be parametrized with values like other types *** */
# n.b. `fn Type (args: ...)` ensure `Type` of given `args`!
length  = fn prelude.Int (length:
            declare { name = "length ${builtins.toString length}"; }
              (fn prelude.List (xs: length == builtins.length xs)));
listOf  = type: let type' = def type; in
            declare { name = "listOf (${type'})"; }
              (fn prelude.List (xs: builtins.all (x: type' x) xs));
setOf   = type: let type' = def type; in
            declare { name = "setOf (${type'})"; }
              (fn prelude.Set (s: listOf type' (builtins.attrValues s)));
# Turn any type declared with `nixpkgs.lib.types` into a validator:
option  = fn prelude.Type (type: with type;
            declare { inherit check name; } None);
both    = fn prelude.List (xs: let xs' = map (x: def x) xs; in
            declare { name = "both [ ${builtins.toString xs'} ]"; }
              (e: builtins.all (type: type e) xs'));
# TODO it would make more sense to name it `either` or to rename `both`:
enum    = fn prelude.List (xs: let xs' = map (x: def x) xs; in
            declare { name = "enum [ ${builtins.toString xs'} ]"; }
              (e: builtins.any (type: type e) xs'));
not     = type: let type' = def type; in
            declare { name = "!(${type'})"; }
              (e: !(type' e));
match   = regex: # FIXME check if `regex` is of `Regex` type!
            declare { name = "match /${regex}/ regex"; }
            (fn prelude.Str (str: builtins.match regex str != null));

# From https://www.rfc-editor.org/rfc/rfc3986#page-50
Url     = match ''^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?'';

Drv = declare { name = "Derivation"; } { type = "derivation"; };
Maybe = declare { name = "Maybe"; } (x: enum [ Null x ]); # TODO
Unit = declare { name = "{}"; } { }; # TODO: This just behaves like Set type ...

/* *** Some type ideas for the future *** */
Hash    = TODO; # FIXME SRI hashes used by Nix :)
Regex   = TODO; # It would be nice to check if a RegEx is valid ...
Json    = TODO; # ... or if JSON data could be parsed?
SemVer  = TODO; # ... or if a software version is in SemVer format!

}; ############################################################################

# This is internal mixture that helps to have declared types available here:
prelude = (builtins.mapAttrs (n: _: declare { name = n; } types.${n}) types);

# Compatibility with https://code.tvl.fyi/about/nix/yants :)
# blob: f2318fa54a0f464b0e61afa181fbe7b24d632ccd

yants = with prelude;
# TODO: redefine `is` such as it return a functor and not an opaque lamda ...
let unwrap = f: declare { name = "?"; } (x: (builtins.tryEval (f x)).success);
    opt = name: if Str name
                then x: is (declare { inherit name; } x)
                else is (def name);
in {
  any = is Any;
  attrs = x: is (setOf (unwrap x));
  bool = is Bool;
  defun = args: f:
      let x  = builtins.head args;
          xs = builtins.tail args; in
      i: (if builtins.length args > 2
          then defun
          else builtins.head)
        xs (f (x i));
  drv = is Drv;
  either = t1: t2: is (prelude.enum [ (unwrap t1) (unwrap t2) ]);
  eitherN = x: is (prelude.enum (builtins.map unwrap x));
  # FIXME: add support to pattern matching as .match "foo" { foo = ...; }
  enum = opt prelude.enum;
  float = is Float;
  function = is (prelude.enum [ Lambda Functor ]);
  int = is Int;
  list = x: is (listOf (unwrap x));
  null = is Null;
  option = is Maybe;
  path = is Path;
  restrict = name: pred: t: x: contract { inherit name; } (pred (def t x));
  string = is Str;
  struct = opt;
  sum = opt both;
  type = is Type;
  unit = is Unit;
};

in prelude // {
  # Explicitly choose what would be our library interface (and eventually not)
  inherit declare def default contract is fn strict yants;
}
