#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pycryptodome"]
# ///
"""Find the names of hashtag channels your radio hears but can't read.

A hashtag channel's key is SHA-256(name)[:16], so a name can be checked against a real packet:
the 1-byte channel hash must match, the 2-byte HMAC must verify, and the decrypted packet must be
a real message (plausible timestamp, plain-text flags, valid UTF-8 "sender: message"). The radio
keeps the latest unreadable channel packets for this (GET /api/listening/samples). Private
channels (random secrets) can't be found this way.

  uv run firmware/tools/find_channel_names.py                       # seed list + every name up to 4 characters
  uv run firmware/tools/find_channel_names.py --fast 7 --variants   # on a Mac: up to 7 characters (~45 min) and
                                                                    # ~150M dictionary/Polish names with variants
  uv run firmware/tools/find_channel_names.py --fast 6 --listen     # ...and add what's found to the radio

--fast compiles chanfind.c (next to this script) (macOS CommonCrypto, all cores, ~36M names a second on an M4 Max).
Found names can also be added by hand: MeshChat → sidebar + → Listen only, or POST /api/listening.
"""
import argparse, hashlib, hmac, itertools, json, os, pathlib, string, struct, subprocess, sys, unicodedata, urllib.request
from Crypto.Cipher import AES

HERE = pathlib.Path(__file__).resolve().parent

# Names seen on Polish lists plus likely regional/topical ones; the radio tries the same list.
SEED = """polska bot test testing tech hamradio info pogoda sos emergency pomoc help random offtopic off-topic chat ping echo
meshcore mesh lora repeater repeatery news ogolny general lokalny local nocna sp aprs sar osp ratownictwo gory hiking rower
drony dev firmware solar antena anteny slask slaskie silesia gornyslask katowice gliwice zabrze bytom sosnowiec tychy bielsko
rybnik opole opolskie czestochowa cz-wa czwa cze jura zawiercie myszkow lubliniec klobuck radomsko olsztyn krakow malopolska
malopolskie tatry zakopane podhale beskidy tarnow rzeszow podkarpacie kielce swietokrzyskie lodz lodzkie warszawa waw
mazowsze mazowieckie wroclaw wroc-tech legnica dolnoslaskie ds-test wlkp poznan bydgoszcz torun kujawy gdansk trojmiasto
pomorze szczecin zachod wschod poludnie polnoc lublin lubelskie bialystok podlasie warmia mazury lubuskie jokes sports
pixels weather traffic ham memes music games czat rozmowy pogaduchy luz kawa piwo grill auto moto kolej pkp drogi
ostrzezenia alerty burza burze sta radsr""".split()

# --variants: each word as is and with the usual decorations
PREFIXES = ["", "mesh", "mesh-", "meshcore-", "mc-", "mc", "pl-", "sp-", "test-", "the"]
SUFFIXES = ["", "1", "2", "3", "0", "01", "mesh", "-mesh", "_mesh", "bot", "-bot", "_bot", "test", "-test", "chat", "-chat",
            "pl", "-pl", "net", "core", "-net", "news", "-news", "-info", "info", "s", "y", "owo", "-lora", "lora", "-sf6", "sf6", "-sf8"]
DICTS = ["/usr/share/dict/words", "/usr/share/dict/propernames", "/usr/share/dict/connectives", "/usr/share/dict/web2a"]


def key_of(name):
    return hashlib.sha256(name.encode()).digest()[:16]


def chash(key):
    return hashlib.sha256(key).digest()[0]


def try_name(name, payloads):
    """payloads: raw GRP_TXT payloads (hash, mac[2], ciphertext). Returns the messages it decrypts, or []."""
    key = key_of(name)
    h = chash(key)
    out = []
    secret = key + bytes(16)                       # MeshCore uses a 32-byte secret, zero-padded
    for p in payloads:
        if p[0] != h or len(p) < 3 + 16 or (len(p) - 3) % 16:
            continue
        mac, ct = p[1:3], p[3:]
        if hmac.new(secret, ct, hashlib.sha256).digest()[:2] != mac:
            continue
        plain = AES.new(key, AES.MODE_ECB).decrypt(ct)
        ts, flags = struct.unpack("<IB", plain[:5])
        try:
            text = plain[5:].rstrip(b"\0").decode("utf-8")
        except UnicodeDecodeError:
            continue
        # a 1-in-65536 MAC fluke decrypts to noise: demand a real-looking message
        if 1_600_000_000 < ts < 1_950_000_000 and flags >> 2 == 0 and ": " in text and text.isprintable():
            out.append(text)
    return out


def fold(s):
    return unicodedata.normalize("NFKD", s.replace("ł", "l").replace("Ł", "L")).encode("ascii", "ignore").decode()


def variant_names(extra_files):
    """SEED, the Polish list, the system dictionaries and any --words files, each with PREFIXES/SUFFIXES."""
    bases = set(SEED)
    for f in [str(HERE / "channel-words-pl.txt"), *DICTS, *extra_files]:
        if not os.path.exists(f):
            continue
        for line in open(f, encoding="utf-8", errors="ignore"):
            for w in line.split() if f.endswith("-pl.txt") else [line.strip()]:
                w = w.strip().lower().lstrip("#")
                if 1 <= len(w) <= 24:
                    bases.add(w)
    forms = set()
    for b in bases:
        for v in {b, b.replace(" ", "-"), b.replace(" ", ""), b.replace(" ", "_"), b.replace("-", ""), b.replace("-", "_"), fold(b)}:
            if v and " " not in v:
                forms.add(v)
    yield from forms
    for f in forms:
        if len(f) <= 16:
            for p in PREFIXES:
                for s in SUFFIXES:
                    if p or s:
                        yield p + f + s


def chanfind():
    """chanfind.c (next to this script), built on first use (macOS only: it uses CommonCrypto)."""
    src, exe = HERE / "chanfind.c", HERE / ".chanfind"
    if sys.platform != "darwin":
        sys.exit("--fast needs macOS (CommonCrypto); use --brute instead")
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["cc", "-O3", "-o", str(exe), str(src)], check=True)
    return str(exe)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--radio", default="http://meshcore.local", help="the radio running MeshChat (default http://meshcore.local)")
    ap.add_argument("--samples", help="read samples from this JSON file instead of the radio")
    ap.add_argument("--words", action="append", default=[], help="extra names, one per line (with or without #)")
    ap.add_argument("--brute", type=int, default=4, help="every name of a-z0-9- up to this length, in Python (default 4)")
    ap.add_argument("--fast", type=int, metavar="N", help="every name up to N characters with chanfind.c (macOS); 6 takes ~1 min, 7 ~45 min")
    ap.add_argument("--variants", action="store_true", help="also the system dictionaries and the Polish list, with common prefixes/suffixes")
    ap.add_argument("--listen", action="store_true", help="add the names found to the radio's listening list")
    a = ap.parse_args()
    raw = json.load(open(a.samples)) if a.samples else json.load(urllib.request.urlopen(f"{a.radio}/api/listening/samples", timeout=15))
    payloads = [bytes.fromhex(s["payload"]) for s in raw]
    hexes = [s["payload"] for s in raw]
    hashes = sorted({p[0] for p in payloads})
    print(f"{len(payloads)} stored packets on {len(hashes)} unreadable channels: {' '.join(f'{h:02x}' for h in hashes)}")

    words = [f"#{w}" for w in SEED]
    for f in a.words:
        words += [f"#{w.strip().lstrip('#')}" for w in open(f, encoding="utf-8") if w.strip()]
    found = {}

    def confirm(names):
        for name in names:
            if name in found:
                continue
            texts = try_name(name, payloads)
            if texts:
                found[name] = texts
                print(f"FOUND {name}  ({chash(key_of(name)):02x}, {len(texts)} packet{'s' if len(texts) > 1 else ''})  e.g. {texts[0][:70]!r}", flush=True)

    if a.fast:
        exe = chanfind()
        print(f"names up to {a.fast} characters, all cores…", flush=True)
        r = subprocess.run([exe, "brute", str(a.fast), *hexes], capture_output=True, text=True)
        confirm(r.stdout.split())
        print(f"  {r.stderr.strip()}")
        lists = itertools.chain(words, (f"#{n}" for n in variant_names(a.words))) if a.variants else iter(words)
        print("word lists…", flush=True)
        p = subprocess.Popen([exe, "words", *hexes], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, err = p.communicate("\n".join(lists))
        confirm(out.split())
        print(f"  {err.strip()}")
    else:
        alphabet = string.ascii_lowercase + string.digits + "-"
        brute = ("#" + "".join(t) for n in range(1, a.brute + 1) for t in itertools.product(alphabet, repeat=n))
        lists = itertools.chain(words, (f"#{n}" for n in variant_names(a.words))) if a.variants else iter(words)
        wanted, tried = set(hashes), 0
        cheap = []
        for name in itertools.chain(lists, brute):
            tried += 1
            if chash(key_of(name)) in wanted:       # cheap filter: 1 in 256 names gets the full check
                cheap.append(name)
                if len(cheap) >= 1000:
                    confirm(cheap); cheap = []
        confirm(cheap)
        print(f"tried {tried:,} names")

    print(f"found {len(found)}" + ("" if found else " (the rest are private channels or longer names)"))
    if found and a.listen:
        for name in found:
            req = urllib.request.Request(f"{a.radio}/api/listening", data=json.dumps({"name": name}).encode(),
                                         headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=15) as r:
                print(f"listening to {name}: {r.read().decode()}")


if __name__ == "__main__":
    sys.exit(main())
