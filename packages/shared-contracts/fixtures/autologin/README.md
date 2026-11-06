# Anmeldeformulare (NACHGEBAUT)

Nachgebaute Anmeldeseiten fuer die automatische Anmeldung (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md). Keine echten
Seiten, keine echten Daten: nur Aufbau und Feldnamen, wie sie die vorhandenen Abgleiche benutzen (app/studip_sync.py:
`loginname`/`password`/`_eventId_proceed`; app/qis.py: `asdf`/`fdsa`; app/cas.py: `username`/`password`; app/sogo.py:
`loginForm`/`passwordField`/`app.creds.username`) bzw. wie Moodle und SimpleSAMLphp sie standardmaessig haben. Gelesen von
apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/UniAutoLoginTests.swift und UniFlowTests/UniAutoLoginAppTests.swift.
