# Version 1.0.43

* Updating fast_tls to version 1.1.13.
* Updating stun to version 1.0.44.
* Updating p1_utils to version 1.0.23.
* Switch from using Travis to Github Actions as CI

# Version 1.0.42

* Updating fast_tls to version 1.1.12.
* Updating p1_utils to version 1.0.22.
* Updating stun to version 1.0.43.
* Dialyzer reports a warning here that seems a false alarm
* Update record spec: msg gets 'undefined' value in process_data/2
* sock's type is tls_socket(), but that's defined internally in fast_tls
* Tell Dialyzer to not complain about some records that don't match definitions
* p1_server:start_link (nor gen:start) don't support max_queue

# Version 1.0.41

* Updating stun to version 1.0.42.

# Version 1.0.40

* Updating stun to version 1.0.41.
* Updating fast_tls to version 1.1.11.
* Add missing applicaitons in esip.app

# Version 1.0.39

* Updating fast_tls to version 1.1.10.
* Updating stun to version 1.0.40.
* Updating p1_utils to version 1.0.21.

# Version 1.0.38

* Updating stun to version 1.0.39.
* Updating fast_tls to version 1.1.9.
* Exclude old OTP releases from Travis
* Fixes to support compilation with rebar3

# Version 1.0.37

* Updating stun to version 1.0.37.
* Updating fast_tls to version 1.1.8.
* Updating p1_utils to version 1.0.20.

# Version 1.0.36

* Updating stun to version 1.0.36.
* Updating stun to version 1.0.36.

# Version 1.0.35

* Fix compilation with Erlang/OTP 23.0 and Travis
* Updating stun to version 1.0.35.
* Updating fast_tls to version 1.1.7.

# Version 1.0.34

* Updating stun to version 1.0.33.
* Updating fast_tls to version 1.1.6.
* Updating p1_utils to version 1.0.19.

# Version 1.0.33

* Updating fast_tls to version 1.1.5.
* Updating stun to version 1.0.32.

# Version 1.0.32

* Updating stun to version 1.0.31.
* Updating fast_tls to version 1.1.4.
* Updating p1_utils to version 1.0.18.
* Update copyright year

# Version 1.0.31

* Updating stun to version 1.0.30.
* Updating fast_tls to version 1.1.3.
* Updating p1_utils to version 1.0.17.

# Version 1.0.30

* Updating stun to version 1.0.29.
* Updating fast_tls to version 1.1.2.
* Updating p1_utils to version 1.0.16.
* Export useful types

# Version 1.0.29

* Updating stun to version 1.0.28.
* Updating fast_tls to version 1.1.1.
* Updating p1_utils to version 1.0.15.

# Version 1.0.28

* Updating stun to version 1.0.27.
* Updating fast_tls to version 1.1.0.
* Updating p1_utils to version 1.0.14.
* Add contribution guide
* Disable gcov because there is no c part anymore

# Version 1.0.27

* Updating fast_tls to version 1.0.26.
* Updating stun to version 1.0.26.

# Version 1.0.26

* Updating stun to version 1.0.25.
* Updating fast_tls to version 1.0.25.
* Updating p1_utils to version 1.0.13.

# Version 1.0.25

* Updating stun to version 1.0.24.
* Updating fast_tls to version f36ea5b74526c2c1c9c38f8d473168d95804f59d.
* Updating p1_utils to version 6ff85e8.

# Version 1.0.24

* Updating fast_tls to version 1.0.23.
* Updating stun to version 1.0.23.
* Updating p1_utils to version 1.0.12.

# Version 1.0.23

* Updating stun to version 1.0.22.
* Updating fast_tls to version a166f0e.

# Version 1.0.22

* Updating stun to version 1.0.21.
* Updating fast_tls to version 1.0.21.
* Updating p1_utils to version 1.0.11.
* Fix compilation with rebar3

# Version 1.0.21

* Updating fast_tls to version 1.0.20.
* Updating stun to version 1.0.20.

# Version 1.0.20

* Updating stun to version 1.0.19.
* Updating fast_tls to version 1.0.19.

# Version 1.0.19

* Updating stun to version 1.0.18.
* Updating fast_tls to version 71250ae.
* Support SNI for TLS connections 

# Version 1.0.18

* Updating stun to version 1.0.17.
* Updating fast_tls to version 1.0.18.

# Version 1.0.17

* Updating fast_tls to version 1.0.17.
* Updating stun to version 1.0.16.

# Version 1.0.16

* Updating stun to version 1.0.15.
* Updating fast_tls to version 1.0.16.
* Updating p1_utils to version 1.0.10.
* Compatibility with R20

# Version 1.0.15

* Updating stun to version 1.0.14.
* Updating fast_tls to version 1.0.15.

# Version 1.0.14

* Updating fast_tls to version 1.0.14.
* Updating stun to version 1.0.13.

# Version 1.0.13

* Updating stun to version 1.0.12.
* Updating fast_tls to version 1.0.13.

# Version 1.0.12

* Update dependencies (Christophe Romain)

# Version 1.0.11

* Remove calls to erlang:now() (Paweł Chmielowski)
* Update rebar.config.script (Paweł Chmielowski)
* Update dependencies (Christophe Romain)

# Version 1.0.10

* Update fast_tls and stun (Mickaël Rémond)

# Version 1.0.9

* Use p1_utils 1.0.6 (Christophe Romain)
* Make sure esip_codec isn't compiled to native code (Holger Weiss)
* Update fast_tls and stun (Mickaël Rémond)

# Version 1.0.8

* Update dependencies (Mickaël Rémond)

# Version 1.0.7

* Update dependencies (Mickaël Rémond)

# Version 1.0.6

* Update dependencies (Mickaël Rémond)

# Version 1.0.5

* Fix message drops (Evgeny Khramtsov)
* Update Fast TLS and Stun (Mickaël Rémond)

# Version 1.0.4

* Update Fast TLS and Stun (Mickaël Rémond)

# Version 1.0.3

* Update Fast TLS and Stun (Mickaël Rémond)

# Version 1.0.2

* Update Fast TLS and Stun (Mickaël Rémond)

# Version 1.0.1

* Repository is now called esip for consistency (Mickaël Rémond)
* Initial release on Hex.pm (Mickaël Rémond)
* Standard ProcessOne build chain (Mickaël Rémond)
* Support for Travis-CI and test coverage (Mickaël Rémond)
