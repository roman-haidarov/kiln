<h1 align="center">Kiln</h1>

<h2 align="center">A native HTTP runtime for Spinel</h2>

<p align="center"><strong>Ruby-like code. Ahead-of-time compiled. Built for web applications.</strong></p>

---

## Why Kiln

Kiln began when [Spinel](https://github.com/matz/spinel) introduced ahead-of-time
compilation. It opened a path to native web applications written in a familiar,
Ruby-like language, with C handling performance-sensitive networking and
protocol work.

## Ideas behind it

| Project | What inspired Kiln |
| --- | --- |
| [Actix Web](https://github.com/actix/actix-web) | Explicit application composition and a clear separation of concerns |
| [Go net/http](https://github.com/golang/go/tree/master/src/net/http) | A practical, dependable HTTP server foundation |
| Rails | Organizing routes and controllers into focused application files |

Kiln brings these ideas together for Spinel: a small web runtime with explicit
routing, room to organize application code by layer, and native compilation.

## Get started

<p align="center"><a href="getstarted.md"><strong>Installation, examples, and usage →</strong></a></p>
