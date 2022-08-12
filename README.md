# _Contracts_ in Nix

_**NEW:**_ Now `contracts`
[are compatible with `yants`](https://github.com/yvan-sraka/contracts/pull/1).

The Nix language
[lacks a good type system](https://github.com/NixOS/nix/issues/14). There are
already several configuration languages that provide static and even gradual
typing (see, e.g., [Cue](https://cuelang.org/),
[Dhall](https://dhall-lang.org/), or [Nickel](https://nickel-lang.org/)), but
none offer the ability to easily annotate legacy Nix code with types.

"Contracts", which you can now define thanks to the utilities offered in this
library, come to the rescue! And because an example is worth a thousand words:

```nix
{ sources ? import nix/sources.nix }:
with import sources.contracts { enable = true; };

# Describe fields of package.json we will later need, so if the error comes
# from a malformed file, we will fail early:
let package = contract { message = _: "`package.json' malformed..."; } {
  bundleDependencies = enum [ Bool (listOf Str) ];
  dependencies = setOf Str;
} (builtins.fromJSON (builtins.readFile ./package.json));

# We trust the data so we can write simpler logic, even with weird specifications:
# https://docs.npmjs.com/cli/v8/configuring-npm/package-json#bundledependencies
deps = with package;
  if Bool bundleDependencies then
    if bundleDependencies then dependencies
    else {}
  else let filterAttrsName = with builtins; set: xs:
    removeAttrs set (partition (x: elem x xs) (attrNames set)).wrong; in
    filterAttrsName dependencies bundleDependencies;

# I leave the writing of `bundler` (or any working derivation) to the reader!
# Notice that `nixpkgs` wasn't required until now:
pkgs = import sources.nixpkgs {}; in derivation {
  name = "this-is-just-a-dumb-example";
  builder = "${pkgs.bash}/bin/bash";
  args = [ ./bundler (builtins.toFile "deps.json" (builtins.toJSON deps)) ];
  system = builtins.currentSystem;
}
```

What's behind such dark magic? Basic ideas (and a few lines of code):

- The expressiveness of the Nix language is greater than what we expect of most
  type systems, and good news: Nix expression computation is expected to
  terminate (it's not perfect, indeed, but did you know that `C++` template
  system resolution can loop infinitely?).

- Language builtins already offer what is needed to compare primitive types and
  to unpack more complex ones! And those who have played with `nixpkgs`
  constructs know that there is something like (runtime types) in
  [`lib.types`](https://github.com/NixOS/nixpkgs/blob/master/lib/types.nix) to
  define `mkOption`. (I provide insights below on how these two models
  interoperate and, of course, why this one is _greater_.)

And the deadly simple concept of "Validators", a function that takes arbitrary
data and returns a boolean if the data is correct. Developers write validators
on a weekly basis; it's what you're doing, e.g., when you use a regex to check
if a string is a valid URL, or when you check if a value is not `null`. Now
think about having a type `Url` or a type `Not Null`?

```repl
nix-repl> Url "Hello, "
false
nix-repl> not Null "World!"
true
```

Yeah! This library provides such types out of the box, and here's how it works,
just like a function that takes data and returns a `Boolean`. Behind the scenes,
it's a functor for tracing purposes in case of a type error, but really, we
aren't concerned about that yet. Another cool thing here is the `not` operator
(a `Function` that takes a `Type` and returns a `Type`). But before composing
types, let's try to create new ones:

```repl
nix-repl> UniversalAnswer = x: x == 42
nix-repl> UniversalAnswer 43
false
```

But this isn't fully a type; our library needs some extra info, like the type
name, and will save you a few characters (`x: x == ...`) with the `declare`
keyword:

```nix
let UniversalAnswer' = declare { name = "UniversalAnswer"; } 42;
```

I will now use "type" to refer to a validator function passed to our `declare`
keyword (which turns it into a handy functor with `name` and `check` fields)!

> **N.B.** What's really cool here is that our created type is fully compatible
> with `mkOption` requirements, meaning you can use it in declarations:
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
> `declare` doesn’t change the validator behavior; it just gives them the extra
> fields that make them equivalent to a NixOS option!

But what's great with our model here, and what ends the comparison with
`mkOption`, is the ability to just:

```nix
let Login = declare { name = "Login"; } { user = Email; password = Hash; };
```

Wow! The `declare` keyword lets you define validator "types" as arbitrary data
that could itself rely on types in their fields.

> **N.B.** A little friendly warning here: do not confuse `[ Int ]`, which
> should be read as a constraint of "the first element of this list should be an
> `Int`", with `ListOf Int`, which stands for "a homogeneous list, eventually
> empty, that only contains `Int`." This allows us to write things such as
> `[ String Int ]`: the tuple of an `Integer` and a `String`!

The last thing left, now that we've talked a lot about "validators" (our
friendly, cheap runtime types), is to explain what a contract means:

```nix
let contract = type: value: assert type value; value;
```

The real implementation of a contract isn't a one-liner since it actually throws
a _recoverable error_ and prints a _debug trace_, but that's the core idea! Here
is an example:

```nix
let users = contract { name = "valid users.json format"; }
                     (listOf Login) # defined just before!
                     (builtins.fromJSON (builtins.readFile ./users.json));
```

> **N.B.** Like `declare`, our `contract` method takes an extra first argument,
> which is an attribute set of options and could be empty. This is a simple
> design pattern that allows this library to be extended without breaking
> backward compatibility!
>
> The `is` function is an alias of `contract {}`, e.g., `let x = is Int value;`!

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

### With [`npins`](https://github.com/andir/npins)

```shell
npins add github yvan-sraka contracts
```

```nix
{ sources ? import ./npins, ... }:
with import sources.contracts { enable = true; }; {

    /* ... */

}
```

### With [`niv`](https://github.com/nmattia/niv)

```shell
niv add yvan-sraka/contracts
```

```nix
{ sources ? import nix/sources.nix, ... }:
with import sources.contracts { enable = true; }; {

    /* ... */

}
```

### Using classic old-style channels

```shell
nix-channel --add \
  https://github.com/yvan-sraka/contracts/archive/main.tar.gz contracts
nix-channel --update
```

```nix
{ contracts ? import <contracts> { enable = true; }, ... }: with contracts; {

  /* ... */

}
```

## Obligatory warning

This whole proof-of-concept is currently really just a _Work In Progress_ …
e.g., the naming of most of the constructs exposed by the library or internal
mechanisms is likely to change in future versions!

## _Great_ debugging experience

You can give custom names and descriptions to both types and contracts and
customize error messages for a better debugging experience. Here is the kind of
error you can expect from this library:

```trace
trace: `package.json' malformed...
trace: { author = ""; description = ""; license = "ISC"; main = "bundler.js"; name = "test"; scripts = { test = "echo \"Error: no test specified\" && exit 1"; }; version = "1.0.0"; }
error: TypeError: `check` function of the type `{ bundleDependencies = enum [ Bool listOf (Str) ]; dependencies = setOf (Str); }' return `false' ...
       > **N.B.** This error comes from `github:yvan-sraka/contracts' library
(use '--show-trace' to show detailed location information)
```

And, IMO, the great advantage of our runtime cheap types is that they play so
well with lazy evaluation: giving you the right stack trace of where exactly the
value that actually breaks your contract comes from!

**N.B.** If you still don't think that lazy checking is a feature, you can force
the checking of your interface by the concrete evaluation of your value. The
library gives you a `strict` keyword for this purpose.

## Recoverable errors

Contract checking will NEVER trigger non-recoverable errors (that cannot be
caught by `tryEval`).

Remember the previous example, and see the version without a contract:

```repl
nix-repl> json = "{}" # e.g. a bad users.json file!
nix-repl> users = map (x: x.user) (builtins.fromJSON json)
nix-repl> builtins.tryEval(users)
```

This code will fail with this error (which is unrecoverable) …

```trace
error: value is a set while a list was expected
```

Contracts solve that, give it a try! :)

## Opt-out easily

Are you wondering about the runtime cost of such a monstrosity in your fast
package declaration?

First, I will tell you that, in my opinion, nix expression evaluation is pretty
unlikely to be your package-building bottleneck.

Second, be aware that checking can be disabled on demand, e.g., here where the
`enable` attribute is activated only when running on CI:

```nix
{ ... }:
  # Import types as a prelude, but only enable them when the `CI` env variable is set
  with import <contracts> { enable = (builtins.getEnv "CI" != ""); }; {
  # **N.B.** but this is impure and will not work by default in flakes!
}
```

## Dogfooding and self-contained

Types defined in the Nix contract library use the library for greater
readability and correctness, e.g., through the `fn` construct:

```nix
fn = Args: f: x: f (is (def Args) x);
```

This library tries to be as KISS and minimal as possible and, e.g., does not
rely on `nixpkgs` or on anything else other than Nix core builtins.

## Why is this type/construct not available out of the box?

Good question, drop me an email :)
