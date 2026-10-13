(lang dune 3.17)

(name hl-copy-engine)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/hl-copy-engine))

(package
 (name hl-copy-engine)
 (synopsis
  "Copy-trading engine: mirrors leader positions into follower accounts on Hyperliquid")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  ppx_jane
  bin_prot
  cohttp
  cohttp-async
  uri
  yojson
  fixed-decimal
  exchange-core
  hl-protocol
  market-data
  hl-client
  hl-copy-core
  hl-copy-keystore
  (hl-sim :with-test)
  (exchange-core-engine :with-test)))
