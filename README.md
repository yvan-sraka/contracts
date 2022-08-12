# _Contracts_ in Nix

Nix language
[lack of a good type system](https://github.com/NixOS/nix/issues/14). There are
already several initiatives of configuration language that provide static and
even gradual typing (see, e.g., [Cue](https://cuelang.org/),
[Dahl](https://dhall-lang.org/), or [Nickel](https://nickel-lang.org/)), but
none offer the ability to easily annotate legacy Nix code with types. 

“Contracts”, that you can now define thanks to the utilities offered in this
library, comes to the rescue! And because an example worth thousand words:

```nix
{ sources ? import nix/sources.nix }:
with import sources.contracts { enable = true; };

# Describe fields of package.json we will later need, so if the error comes
# from a malformed file, we will fail early:
let package = contract { message = _: "`package.json' malformed..."; } {
  bundleDependencies = enum [ Bool (listOf Str) ];
  dependencies = setOf Str;
} (builtins.fromJSON (builtins.readFile ./package.json));

# We trust data so we can write simpler logic, even with weird specifications:
# https://docs.npmjs.com/cli/v8/configuring-npm/package-json#bundledependencies
deps = with package;
  if Bool bundleDependencies then
    if bundleDependencies then dependencies
    else {}
  else let filterAttrsName = with builtins; set: xs:
    removeAttrs set (partition (x: elem x xs) (attrNames set)).wrong; in
    filterAttrsName dependencies bundleDependencies;

# I left the writing of `bundler` (or of any working derivation) to the reader!
# Notice that `nixpkgs` wasn't required until now:
pkgs = import sources.nixpkgs {}; in derivation {
  name = "this-is-just-a-dumb-example";
  builder = "${pkgs.bash}/bin/bash";
  args = [ ./bundler (builtins.toFile "deps.json" (builtins.toJSON deps)) ];
  system = builtins.currentSystem;
}
```

What's behind such dark magic? Basic ideas (and few lines of code):

- Expressiveness of Nix language is greater than what we expect of most type
  systems, and good news: Nix expression computation are expected to terminate
  (it's not perfect indeed, but do you know we could have C++ template system
  resolution loop infinitely?)

- Language builtins already offer what need to compare primitives types and to
  unpack more complex ones! And those that already played with `nixpkgs`
  constructs knows that there is something like (runtime types) in
  [`lib.types`](https://github.com/NixOS/nixpkgs/blob/master/lib/types.nix) to
  define `mkOption`. (I give below insights on how these 2 models interoperate
  and of course why this one is _greater_)

And the deadly simple concept of “Validators”, a function that take arbitrary
data and return a boolean if the data is correct. Developer wrote validators on
a weekly basis, it's what you're doing, e.g, when you use a regex to check if a
string is a valid URL, or when you check if a value is not `null`. Now think
what about having a type `Url` or a type `not Null`?

```
nix-repl> Url "Hello, "
false
nix-repl> not Null "World!"
true
```

Yeah! This library provides such types out of the box, and here how it works,
just like a function that take data and return a `Boolean`. Behind the wheel
it's a functor for tracing purpose in case of type error, but really we aren't
concerned about that yet. Another cool thing here is the `not` operator (a
`Function` that take a `Type` and return a `Type`). But before composing types,
let's try to create new ones:

```
nix-repl> UniversalAnswer = x: x == 42
nix-repl> UniversalAnswer 43
false
```

But this isn't fully a type, our library need some extra info, like type name
and will save you few characters (`x: x == ...`) with the `declare` keyword:

```nix
let UniversalAnswer' = declare { name = "UniversalAnswer"; } 42;
```

I will now use “type” to refer to a validator function passed to our `declare`
keyword (that turn it into a handy functor with `name` and `check` fields)!

> N.B. What's really cool here is that our created type is fully compatible
> with `mkOption` requirements, meaning you can use it in declaration:
>
> ```nix
> { lib, contracts ? <contracts> { enable = true; } }: with contracts; {
>   option = {
>     homepage = lib.mkOption {
>       type = lib.types.mkOptionType Url; # <--
>       default = "https://nixos.org";
>     };
>   };
> }
> ```
>
> Or reuse types from `nixpkgs`:
>
> ```nix
> {
>   inputs.contracts.url = github:yvan-sraka/contracts/main;
>   outputs = { self, nixpkgs, contracts }:
>     with contracts.nixosModules.default { enable = true; }; {
>     packages.x86_64-linux.default =
>       let Package = option nixpkgs.lib.types.package; in # <--
>         is Package nixpkgs.legacyPackages.x86_64-linux.hello;
>   };
> }
> ```
>
> `declare` don’t change validator behaviour, it just give them the extra
> fields that make them equivalent to an NixOS option!

But, what's really cool with our model here, and that end the comparison with
`mkOption` is the ability to just:

```nix
let Login = declare { name = "Login"; } { user = Email; password = Hash; };
```

Wow! `declare` keyword let you define validators “types” as arbitrary data that
could itself rely on types in their fields.

> N.B. A little friendly warning here, do not mismatch `[ Int ]` which should
> be readded as a constraint of "the first element of this list should be an
> `Int`" and `ListOf Int` which stand for "a homogeneous list, eventually
> empty, that only contains `Int`"'. This allow us to write things such as
> `[ String Int ]`: the tuple of an `Integer` and a `String`!

Last thing left, now that we talked a lot about “validators” (our friendly
cheap runtime types), is to explain what mean a contract:

```nix
let contrat = type: value: assert type value; value;
```

The real implementation of contract isn't a one-liner since it actually throw a
_recoverable error_ and print a _debug trace_, but that's the core idea! Here
is an example:

```nix
let users = contract { name = "valid users.json format"; }
                     (listOf Login) # defined just before!
                     (builtins.fromJSON (builtins.readFile ./users.json));
```

> N.B. Like `declare`, our `contract` methods takes an extra first argument
> which is an attribute set of options and could be empty. This is a simple
> design pattern that would allow this lib to be extended without breaking
> retro-compatibility!
>
> `is` function is an alias of `contract {}`, e.g., `let x = is Int value;`!

That's all folks!

Thanks for reading this Proof of Concept gentle introduction :)

## How to install

### As a flake input

```nix
{
  inputs.contracts.url = github:yvan-sraka/contracts/main;
  outputs = { self, contracts }:
    with contracts.nixosModules.default { enable = true; }; {

    /* ... */

  };
}
```

### With [`niv`](https://github.com/nmattia/niv)

```
niv add yvan-sraka/contracts
```

```nix
{ sources ? import nix/sources.nix, ... }:
with import sources.contracts { enable = true; }; {

    /* ... */

}
```

### Using classic old-style channels

```
sudo nix-channel --add \
  https://github.com/yvan-sraka/contracts/archive/main.tar.gz contracts
sudo nix-channel --update
```

```nix
{ contracts ? import <contracts> { enable = true; }, ... }: with contracts; {

  /* ... */

}
```

## Obligatory warning

This whole repository is currently really just a _Work In Progress_ … e.g.
naming of most of the constructs exposed by library or internal mechanisms are
likely to change in future versions!

## _Great_ debugging experience

You can give custom names and description to both types, contracts and
customize error message for greater debugging experience. Here is the kind of
error you can expect from this library:

```
trace: `package.json' malformed...
trace: { author = ""; description = ""; license = "ISC"; main = "bundler.js"; name = "test"; scripts = { test = "echo \"Error: no test specified\" && exit 1"; }; version = "1.0.0"; }
error: TypeError: `check` function of the type `{ bundleDependencies = enum [ Bool listOf (Str) ]; dependencies = setOf (Str); }' return `false' ...
       > n.b. This error comes from `github:yvan-sraka/contracts' library
(use '--show-trace' to show detailed location information)
```

And, IMO, great advantage of our runtime cheap types are that they are playing
so well with lazy evaluation: giving you the right stack trace of where exactly
come from the value that actually break your contract!

> N.B. if you still don't think that lazy checking is a feature you can force
the checking of your interface by the concrete evaluation of your value, the
library give you a `strict` keyword for this purpose.

## Recoverable errors

Contract checking will NEVER trigger non-recoverable errors (that cannot be
caught by `tryEval`).

Remind this previous example, see the version without contract:

```
nix-repl> json = "{}" # e.g. of a bad users.json file!
nix-repl> users = map (x: x.user) (builtins.fromJSON json)
nix-repl> builtins.tryEval(users)
```

This code will fail with this error (which is unrecoverable) …

```
error: value is a set while a list was expected
```

Contracts solve that, give it a try! :)

## Opt-out easily

You wonder about the runtime cost of such monstrosity in your so fast package
declaration?

First, I will tell you that IMO, nix expression evaluation is pretty unlikely
to be your package building bottleneck.

Second, be aware that checking could be disabled on demand, e.g., here where
the `enable` attribute is activated only when running on CI:

```nix
{ ... }:
  # Import types as a prelude, but only enable it when `CI` env variable is set
  with import <contracts> { enable = (builtins.getEnv "CI" != ""); }; {
  # n.b. but this is impure and will not works in flakes!
}
```

## Dogfooding and self-contained

Types defined in nix contract library use the library to greater readability
and correctness, e.g., through the `fn` construct:

```
fn = Args: f: x: f (is (def Args) x);
```

This library tries to be as KISS and minimal as possible, and e.g., does not
rely on `nixpkgs` or on anything else than Nix core builtins.

## Why this type/construct is not available out of the box?

Good question, write an issue or a PR! :)
