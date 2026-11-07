# Anmeldeformulare (NACHGEBAUT)

Nachgebaute Anmeldeseiten fuer die automatische Anmeldung (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md). Keine echten
Seiten, keine echten Daten: nur Aufbau und Feldnamen, wie sie die vorhandenen Abgleiche benutzen (app/studip_sync.py:
`loginname`/`password`/`_eventId_proceed`; app/qis.py: `asdf`/`fdsa`; app/cas.py: `username`/`password`; app/sogo.py:
`loginForm`/`passwordField`/`app.creds.username`) bzw. wie Moodle und SimpleSAMLphp sie standardmaessig haben. Gelesen von
apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/UniAutoLoginTests.swift und UniFlowTests/UniAutoLoginAppTests.swift.

`hsh-idp-echt.html` und `hsh-idp-fehler.html` (07.11.2026): Aufbau des echten SSO der HsH, ohne Anmeldung gelesen
(Formular `form#f` mit einem Knopf ohne `type`; Fehlerseite „SSO Login – Ein Fehler ist aufgetreten … TrackID“, die der
IdP an diesem Tag auf jede SAML-Anfrage des Campusmanagements zeigte). Werte erfunden.
