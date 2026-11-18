Ich erkläre dir Aufgabe 5.1 Schritt für Schritt, sodass du verstehst, **warum** wir mit dem konjugierten Nenner multiplizieren und wie du am Ende auf $x + yi$ kommst.

---

## 1. Was ist überhaupt eine komplexe Zahl?

Eine komplexe Zahl hat die Form

$$\boxed{z = x + yi}$$

- $x$ ist der **Realteil**
- $y$ ist der **Imaginärteil**
- $i$ ist die imaginäre Einheit

**Ganz wichtig:** $i^2 = -1$

Die Normaldarstellung ist genau diese Form $x + yi$. Im Nenner darf am Ende **kein** $i$ mehr stehen.

---

## 2. Aufgabe (a)

**Gegeben:**

$$\frac{3+4i}{1-2i}$$

### Schritt 1: Mit dem konjugierten Nenner erweitern

Der Nenner ist $1-2i$, der konjugierte Nenner ist $1+2i$ (nur das Vorzeichen vor dem $i$ dreht sich um).

$$\frac{3+4i}{1-2i} \cdot \frac{1+2i}{1+2i}$$

**Warum dürfen wir das?** Weil $\frac{1+2i}{1+2i} = 1$ ist. Mit 1 malnehmen ändert den Wert nicht.

### Schritt 2: Zähler ausmultiplizieren

Jeder Term mit jedem:

$$(3+4i)(1+2i) = 3 \cdot 1 + 3 \cdot 2i + 4i \cdot 1 + 4i \cdot 2i$$

$$= 3 + 6i + 4i + 8i^2$$

Jetzt $i^2 = -1$ einsetzen:

$$= 3 + 10i + 8 \cdot (-1)$$

$$= 3 + 10i - 8$$

$$\boxed{-5 + 10i}$$

### Schritt 3: Nenner ausmultiplizieren

$$(1-2i)(1+2i) = 1^2 - (2i)^2 = 1 - 4i^2 = 1 + 4$$

$$\boxed{5}$$

### Schritt 4: Ergebnis

$$\frac{-5+10i}{5} = -\frac{5}{5} + \frac{10}{5}i$$

$$\boxed{-1 + 2i}$$

---

## 3. Aufgabe (b)

**Gegeben:**

$$\frac{1+i}{1-i}$$

### Schritt 1: Mit dem konjugierten Nenner erweitern

$$\frac{1+i}{1-i} \cdot \frac{1+i}{1+i}$$

### Schritt 2: Zähler ausmultiplizieren

$$(1+i)(1+i) = 1 + i + i + i^2 = 1 + 2i - 1$$

$$\boxed{2i}$$

### Schritt 3: Nenner ausmultiplizieren

$$(1-i)(1+i) = 1 - i^2 = 1 + 1$$

$$\boxed{2}$$

### Schritt 4: Ergebnis

$$\frac{2i}{2} = i = 0 + 1i$$

$$\boxed{i}$$

---

## 4. Aufgabe (c)

**Gegeben:**

$$\frac{2+i}{3-i}$$

### Schritt 1: Mit dem konjugierten Nenner erweitern

$$\frac{2+i}{3-i} \cdot \frac{3+i}{3+i}$$

### Schritt 2: Zähler ausmultiplizieren

$$(2+i)(3+i) = 6 + 2i + 3i + i^2 = 6 + 5i - 1$$

$$\boxed{5 + 5i}$$

### Schritt 3: Nenner ausmultiplizieren

$$(3-i)(3+i) = 9 - i^2 = 9 + 1$$

$$\boxed{10}$$

### Schritt 4: Ergebnis

$$\frac{5+5i}{10} = \frac{1}{2} + \frac{1}{2}i$$

$$\boxed{\frac{1}{2} + \frac{1}{2}i}$$

---

## 5. Die wichtigste Regel für deine Klausur

> **Merke: Komplexe Brüche lösen – immer gleich!**
>
> 1. Nenner anschauen.
> 2. Mit dem konjugierten Nenner erweitern.
> 3. Zähler ausmultiplizieren.
> 4. Nenner ausmultiplizieren: $(a+bi)(a-bi) = a^2 + b^2$
> 5. In $x + yi$ aufteilen.

**Alle drei Ergebnisse**

| Aufgabe | Normaldarstellung |
|---|---|
| (a) | $-1 + 2i$ |
| (b) | $i$ |
| (c) | $\frac{1}{2} + \frac{1}{2}i$ |

Hast du verstanden, warum bei Aufgabe (a) aus $8i^2$ plötzlich $-8$ wird?
