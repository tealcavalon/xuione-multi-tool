#!/bin/bash
exec >> /root/xui_ffbuild/build.log 2>&1
set -u
VER=4.4.5
SLOT=4.4
WRAP=0
DEST=/home/xui/bin/ffmpeg_bin/$SLOT
WORK=/root/xui_ffbuild/src
JOBS=$(nproc 2>/dev/null || echo 2)
mark() { echo "$1" > /root/xui_ffbuild/state; echo "=== $1 $(date -u +%H:%M:%S)"; }
fail() { echo "FAIL:$1" > /root/xui_ffbuild/state; echo "!! $1"; exit 1; }

mark PHASE:deps
export DEBIAN_FRONTEND=noninteractive
add-apt-repository -y multiverse || true
apt-get update -qq || fail "apt-get update"
apt-get install -y -qq build-essential nasm yasm pkg-config git wget xz-utils \
  ca-certificates zlib1g-dev libbz2-dev libssl-dev libnuma-dev \
  || fail "as ferramentas de compilacao"

# funcionalidade | pacote | modulo pkg-config (vazio = deixa-se ao configure)
FEATURES="
libx264|libx264-dev|x264
libx265|libx265-dev|x265
libvpx|libvpx-dev|vpx
libxvid|libxvidcore-dev|
libvidstab|libvidstab-dev|vidstab
libaom|libaom-dev|aom
libopencore-amrnb|libopencore-amrnb-dev|opencore-amrnb
libopencore-amrwb|libopencore-amrwb-dev|opencore-amrwb
libmp3lame|libmp3lame-dev|
libopus|libopus-dev|opus
libvorbis|libvorbis-dev|vorbis
libtheora|libtheora-dev|theora
libfdk-aac|libfdk-aac-dev|fdk-aac
libwebp|libwebp-dev|libwebp
libsrt|libsrt-openssl-dev|srt
librtmp|librtmp-dev|librtmp
libfribidi|libfribidi-dev|fribidi
libspeex|libspeex-dev|speex
libxml2|libxml2-dev|libxml-2.0
libxavs|libxavs-dev|
libfreetype|libfreetype6-dev|freetype2
fontconfig|libfontconfig1-dev|fontconfig
libopenjpeg|libopenjp2-7-dev|libopenjp2
libsvtav1|libsvtav1-dev|SvtAv1Enc
"
HAVE=(); MISS=()
while IFS='|' read -r feat pkg mod; do
  [ -n "$feat" ] || continue
  if ! apt-get install -y -qq "$pkg"; then
    # libsrt is packaged under three names depending on the release and the
    # TLS the distribution chose. On 20.04 neither of the first two exists,
    # which is what a live server reported:
    #   E: Unable to locate package libsrt-openssl-dev
    #   E: Unable to locate package libsrt-gnutls-dev
    ALT=""
    [ "$feat" = libsrt ] && ALT="libsrt-gnutls-dev libsrt-dev"
    GOT=0
    for a in $ALT; do
      apt-get install -y -qq "$a" && { GOT=1; break; }
    done
    [ "$GOT" = 1 ] || { MISS+=("$feat: nao ha $pkg"); continue; }
  fi
  if [ -n "$mod" ] && ! pkg-config --exists "$mod"; then
    MISS+=("$feat: instalado, o pkg-config nao ve $mod"); continue
  fi
  HAVE+=("$feat")
done <<< "$FEATURES"

mark PHASE:nvidia
mkdir -p "$WORK" && cd "$WORK" || fail "nao consigo escrever em $WORK"
NV=0
# The newest headers rather than a pinned tag. n11.1.5.1 was pinned here and
# ffmpeg asks for a minimum that climbs with every release — 7 and up want
# 12.x — so on a live 20.04 LB every one of the five candidate versions was
# refused with
#
#   ERROR: cuvid requested, but not all dependencies are satisfied: ffnvcodec
#
# on a machine that has no NVIDIA card at all. The tag is kept only as the
# fallback, for the day github is reachable but the default branch is not.
# Refreshed rather than reused. A server that has already failed this build
# has the old pinned checkout sitting in $WORK, and "it is already there" is
# what would hand it the same headers and the same failure on every retry.
# The new one replaces the old only once it is on disk, so a machine that
# cannot reach github keeps whatever it had.
rm -rf nv-new
if git clone -q --depth 1 \
     https://github.com/FFmpeg/nv-codec-headers.git nv-new \
   || git clone -q --branch n12.2.72.0 --depth 1 \
      https://github.com/FFmpeg/nv-codec-headers.git nv-new; then
  rm -rf nv-codec-headers && mv nv-new nv-codec-headers
fi
rm -rf nv-new
[ -d nv-codec-headers ] && (cd nv-codec-headers && make install PREFIX=/usr/local) || true
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
# Asked of pkg-config, not of `make install` exiting 0. What decides whether
# configure takes --enable-ffnvcodec is whether pkg-config can see it, and a
# successful install of headers this ffmpeg considers too old is exactly the
# case that brought the whole build down.
if pkg-config --exists ffnvcodec 2>/dev/null; then
  NV=1
else
  MISS+=("nvenc/cuvid: o pkg-config nao ve ffnvcodec")
fi

mark PHASE:source
cd "$WORK" || fail "sem $WORK"
if [ "$VER" = latest ]; then
  # Asked of ffmpeg.org rather than pinned here: a number written into this
  # script is a guess at a list nobody can see from where it was written.
  #
  # A list, not a number. ffmpeg removes options between major releases —
  # 9.0.1 has no --enable-postproc at all — and while most of that is handled
  # by dropping the option and asking again, a release can also simply be one
  # this panel's feature set cannot be had from. So the newest of each series
  # is kept, newest first, and the next one is what happens when configure
  # cannot be satisfied on this one.
  ALL=$(wget -qO- https://ffmpeg.org/releases/ 2>/dev/null \
        | grep -o 'ffmpeg-[0-9][0-9.]*\.tar\.xz' \
        | sed -e 's/^ffmpeg-//' -e 's/\.tar\.xz$//')
  [ -n "$ALL" ] || fail "nao consegui saber quais as versoes que existem"
  CANDS=$(printf '%s\n' $ALL \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | awk -F. '{s[$1"."$2]=$0} END{for (k in s) print s[k]}' \
        | sort -t. -k1,1nr -k2,2nr | head -5)
  echo "LATEST:$(printf '%s\n' $CANDS | head -1)"
  echo "CANDIDATES:$(printf '%s ' $CANDS)"
else
  CANDS=$VER
fi

# What ffmpeg calls a thing in its error, and the option that turns it on.
drop_of() {
  case "$1" in
    SvtAv1Enc) echo libsvtav1 ;;   libfdk_aac|fdk-aac) echo libfdk-aac ;;
    x264|libx264) echo libx264 ;;  x265|libx265) echo libx265 ;;
    vpx|libvpx*) echo libvpx ;;    libxvid*|xvid*) echo libxvid ;;
    vidstab|libvidstab) echo libvidstab ;;  aom|libaom) echo libaom ;;
    opencore-amrnb|libopencore_amrnb) echo libopencore-amrnb ;;
    opencore-amrwb|libopencore_amrwb) echo libopencore-amrwb ;;
    libmp3lame|mp3lame) echo libmp3lame ;;  opus|libopus) echo libopus ;;
    vorbis|libvorbis) echo libvorbis ;;     theora|libtheora) echo libtheora ;;
    libwebp) echo libwebp ;;                srt|libsrt) echo libsrt ;;
    librtmp) echo librtmp ;;                fribidi|libfribidi) echo libfribidi ;;
    speex|libspeex) echo libspeex ;;        libxml-2.0|libxml2) echo libxml2 ;;
    libxavs) echo libxavs ;;   freetype2|libfreetype) echo libfreetype ;;
    fontconfig) echo fontconfig ;;  libopenjp2|libopenjpeg) echo libopenjpeg ;;
    ffnvcodec|nvenc|cuvid) echo "ffnvcodec nvenc cuvid" ;;
    *) echo "" ;;
  esac
}

# The table above is written by hand, so it is always one release behind
# something. When a name is not in it the option we actually passed is looked
# for instead: whatever --enable- carries that name is the one being refused.
# A name we never wrote down then costs one option instead of the whole build.
guess_drop() {
  n=$(echo "$1" | tr 'A-Z' 'a-z' | tr -d '_.-')
  for o in $OPTS; do
    case "$o" in --enable-*) ;; *) continue ;; esac
    e=${o#--enable-}
    c=$(echo "$e" | tr 'A-Z' 'a-z' | tr -d '_.-')
    if [ "$c" = "$n" ] || [ "$c" = "lib$n" ] || [ "lib$c" = "$n" ]; then
      echo "$e"; return
    fi
  done
  echo ""
}

# A newer assembler, built where the distribution's is too old for ffmpeg's
# own macros. Read off a live 20.04, on 9.0.1 and on 8.1.2 alike:
#
#   libavcodec/x86/vp8dsp.asm:416: error: (ALLOC_STACK:4) expecting `)'
#
# Same file, same options, and 22.04 assembles it. ffmpeg's configure asks
# only for nasm >= 2.13, which 20.04's 2.14.02 satisfies, so nothing is said
# until make reaches the first .asm the newer x86inc macros touch. Built to
# /usr/local/bin, which is ahead of /usr/bin in root's PATH; nothing runs it
# but a build, and the distribution's own copy is left where it is.
build_nasm() {
  ( cd "$WORK" || exit 1
    rm -rf nasm-build && mkdir -p nasm-build && cd nasm-build || exit 1
    for nv in 2.16.03 2.15.05; do
      if wget -q "https://www.nasm.us/pub/nasm/releasebuilds/$nv/nasm-$nv.tar.xz"; then
        tar xf "nasm-$nv.tar.xz" || continue
        cd "nasm-$nv" || continue
        ./configure --prefix=/usr/local > /dev/null 2>&1 || exit 1
        make -j"$JOBS" > /dev/null 2>&1 || exit 1
        # The binary, not `make install`: nasm's install target also lays
        # down manpages, and a missing doc tool is not a reason to have
        # gone to the trouble of compiling an assembler.
        install -m 0755 nasm /usr/local/bin/nasm || exit 1
        install -m 0755 ndisasm /usr/local/bin/ndisasm 2>/dev/null
        exit 0
      fi
    done
    exit 1 ) || return 1
  hash -r
  nasm -v > /dev/null 2>&1 || return 1
  echo "NASM:$(nasm -v 2>/dev/null | head -1)"
  return 0
}

OK=0
GOTIT=0
# Once per build, not once per release. If the assembler was behind for 9.0.1
# it is behind for 8.1.2, and compiling it a second time proves nothing.
ASMFIXED=0
# What the machine itself could not provide, as against what one release or
# another could not. The first belongs to every attempt; the second belongs
# to the release that was refused, and reporting 9.0.1's dropped options
# beside a 8.1.2 that was actually installed is a plain untruth.
MISSBASE=("${MISS[@]}")
for TRY in $CANDS; do
  [ "$GOTIT" = 1 ] && break
  VER=$TRY
  OK=0
  MISS=("${MISSBASE[@]}")
  cd "$WORK" || fail "sem $WORK"
  if [ ! -d "ffmpeg-$VER" ]; then
    if ! wget -q "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"; then
      echo "SKIPPED:$VER:nao esta em ffmpeg.org"; continue
    fi
    tar xf "ffmpeg-$VER.tar.xz" || { echo "SKIPPED:$VER:tar"; continue; }
  fi
  cd "ffmpeg-$VER" || { echo "SKIPPED:$VER:sem pasta"; continue; }
  echo "BUILDING:$VER"

  mark PHASE:patch
  if command -v python3 >/dev/null 2>&1; then
    cat > /root/xui_ffbuild/segpatch.py <<'XUIPATCHEOF'

import io, re, sys

P = "libavformat/segment.c"
MARK = "XUIONE-SEGMENT-DELETE"
try:
    src = io.open(P, encoding="utf-8", errors="surrogateescape").read()
except OSError as e:
    print("PATCH:no_file:%s" % e); sys.exit(1)
if MARK in src:
    print("PATCH:already"); sys.exit(0)

out, done = src, []

# 1. unlink() needs it, and segment.c does not include it on its own.
a = '#include "avformat.h"'
if a not in out:
    print("PATCH:miss:include"); sys.exit(1)
out = out.replace(a, "#include <unistd.h> /* %s */\n%s" % (MARK, a), 1)
done.append("include")

# 2. The flag, beside the two already there. Its value is taken from the
#    LIVE line rather than written down here: the numbering is the file's
#    business, and 1 << 1 and 2 are both spellings it has used.
m = re.search(r"^#define\s+SEGMENT_LIST_FLAG_LIVE\s+(.+?)\s*$", out, re.M)
if not m:
    print("PATCH:miss:define"); sys.exit(1)
live = m.group(1).strip()
val = "(%s << 1)" % live if "<<" not in live else live.replace("1)", "2)")
if "<<" in live:
    b = re.search(r"<<\s*(\d+)", live)
    val = re.sub(r"<<\s*\d+", "<< %d" % (int(b.group(1)) + 1), live) if b else "4"
else:
    val = str(int(live) * 2) if live.isdigit() else "4"
out = out[:m.end()] + "\n#define SEGMENT_LIST_FLAG_DELETE %s /* %s */" % (val, MARK) + out[m.end():]
done.append("define")

# 3. The option, so -segment_list_flags can name it. Modelled on the "live"
#    line in the same table, which fixes the struct shape for this release
#    instead of guessing at it.
m = re.search(r'^([ \t]*)\{\s*"live"\s*,.*SEGMENT_LIST_FLAG_LIVE.*$', out, re.M)
if not m:
    print("PATCH:miss:option"); sys.exit(1)
line = m.group(0)
new = line.replace('"live"', '"delete"')
new = new.replace("enable live-friendly list generation (useful for HLS)",
                  "delete segment files no longer in the playlist")
new = new.replace("SEGMENT_LIST_FLAG_LIVE", "SEGMENT_LIST_FLAG_DELETE")
out = out[:m.end()] + "\n" + new + " /* %s */" % MARK + out[m.end():]
done.append("option")

# 4. And the deletion itself, in the block that already drops the entry —
#    ffmpeg frees the name and leaves the file.
a = "seg->segment_list_entries = seg->segment_list_entries->next;"
if out.count(a) != 1:
    print("PATCH:miss:drop:%d" % out.count(a)); sys.exit(1)
out = out.replace(a, a + "\n"
    "                if (seg->list_flags & SEGMENT_LIST_FLAG_DELETE) /* %s */\n"
    "                    unlink(entry->filename); /* %s */" % (MARK, MARK), 1)
done.append("unlink")

if len(done) != 4:
    print("PATCH:incomplete:%s" % ",".join(done)); sys.exit(1)
io.open(P, "w", encoding="utf-8", errors="surrogateescape").write(out)
# Read back: "I wrote it" is not "it is there".
back = io.open(P, encoding="utf-8", errors="surrogateescape").read()
for need in ("#include <unistd.h>", "#define SEGMENT_LIST_FLAG_DELETE",
             '"delete"', "unlink(entry->filename)"):
    if need not in back:
        print("PATCH:lost:%s" % need); sys.exit(1)
print("PATCH:ok:%s" % ",".join(done))
XUIPATCHEOF
    PR=$(python3 /root/xui_ffbuild/segpatch.py 2>&1 | tail -1)
    echo "SEGPATCH:$VER:$PR"
    case "$PR" in
      PATCH:ok*|PATCH:already)
        echo "segment: flag delete acrescentada ao ffmpeg $VER" >> /root/xui_ffbuild/notes ;;
      *)
        echo "segment: nao consegui acrescentar a flag delete ($PR)" >> /root/xui_ffbuild/notes ;;
    esac
  else
    echo "segment: sem python3, a flag delete nao foi acrescentada" >> /root/xui_ffbuild/notes
  fi

  mark PHASE:configure
OPTS="--prefix=/usr/local --extra-version=XUI.one-compat
      --enable-gpl --enable-version3 --enable-nonfree
      --enable-openssl --enable-postproc --enable-pthreads --enable-gray
      --enable-bzlib --enable-zlib --enable-pic --enable-small
      --enable-runtime-cpudetect
      --disable-autodetect --disable-debug --disable-doc --disable-ffplay
      --disable-alsa --disable-indev=alsa --disable-outdev=alsa"
for f in "${HAVE[@]}"; do OPTS="$OPTS --enable-$f"; done
if [ "$NV" = 1 ]; then
  OPTS="$OPTS --enable-ffnvcodec --enable-nvenc --enable-cuvid"
  command -v nvcc >/dev/null 2>&1 && OPTS="$OPTS --enable-cuda-nvcc"
fi
# Two ways for configure to say no, and they are different answers.
#
#   ERROR: SvtAv1Enc >= 0.8.4 not found using pkg-config
#     the option exists and this machine cannot satisfy it — drop the option.
#
#   Unknown option "--enable-postproc".
#     the option does not exist in this ffmpeg at all. ffmpeg removes options
#     between major releases and 9.0.1 has no --enable-postproc; the option
#     is named in the message, so there is nothing to map.
#
# Neither is a reason to change ffmpeg version. Dropping the option and
# asking again costs a configure; changing version costs the whole build.
CLOG=/root/xui_ffbuild/configure-$VER.log
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ./configure $OPTS > "$CLOG" 2>&1; then OK=1; break; fi
  # The option named back at us, verbatim.
  GONE=$(sed -n 's/.*Unknown option "--enable-\([A-Za-z0-9_.+-]*\)".*/\1/p' \
         "$CLOG" | head -1)
  WHYG=""
  if [ -n "$GONE" ]; then
    WHYG="o ffmpeg $VER nao tem essa opcao"
  else
    # Four shapes, all of them naming something ffmpeg could not satisfy. The
    # dependency one names two things — what was asked for and what it needed
    # — and both are dropped, because dropping only the first brings the
    # second back on the next attempt and spends a configure to learn it.
    #
    #   ERROR: cuvid requested, but not all dependencies are satisfied: ffnvcodec
    #
    BAD=$(sed -n -e 's/^ERROR: \([A-Za-z0-9_.+-]*\).*not found.*/\1/p' \
                 -e 's/^ERROR: \([A-Za-z0-9_.+-]*\) requested but not.*/\1/p' \
                 -e 's/^ERROR: \([A-Za-z0-9_.+-]*\) requested, but not all dependencies are satisfied: *\(.*\)/\1 \2/p' \
                 -e 's/^ERROR: [Cc]ould not find \([A-Za-z0-9_.+-]*\).*/\1/p' \
                 "$CLOG" | head -1)
    for b in $BAD; do
      g=$(drop_of "$b")
      [ -n "$g" ] || g=$(guess_drop "$b")
      [ -n "$g" ] && GONE="$GONE $g"
    done
    if [ -n "$GONE" ]; then
      GONE=$(printf '%s\n' $GONE | sort -u | tr '\n' ' ')
      WHYG="o configure do ffmpeg $VER recusou-o ($BAD)"
    fi
  fi
  if [ -z "$GONE" ]; then
    # Keep the reason, not the tail. ffmpeg ends a failed configure with five
    # lines telling you to mail the mailing list, so the last lines of the log
    # are always those five and never the reason. The reason is the ERROR:
    # line above them; when there is none, the last line that is not blurb.
    WHY=$(grep -m1 '^ERROR:' "$CLOG")
    [ -n "$WHY" ] || WHY=$(grep -vE '^(If you think configure|version from Git|ffmpeg-user@|Include the log file|help solve the problem)|mailing list or IRC|^$' \
                           "$CLOG" | tail -1)
    echo "$VER|configure|${WHY:-o configure parou sem dizer porque}" >> /root/xui_ffbuild/why
    echo "SKIPPED:$VER:configure"
    break
  fi
  for g in $GONE; do
    OPTS=$(echo "$OPTS" | sed "s/--enable-$g\b//g")
    MISS+=("$g: $WHYG")
  done
done
  [ "$OK" = 1 ] || continue
  echo "BUILT_VERSION:$VER"

  mark PHASE:make
  # The long part, and the reason the candidate list is walked rather than
  # tried once: everything from here down can disqualify a release, and the
  # answer to a disqualified release is the next release. It used to stop
  # here instead, on the reasoning that half an hour of CPU is not something
  # to spend twice unasked — true of a machine that cannot build, and wrong
  # about a release this panel cannot use, because "latest" resolves to that
  # same release on every retry and the screen has no way to ask for another.
  # Through tee rather than straight to the log: the log has to keep moving
  # while a half-hour compile runs, because a log that stops is how a stalled
  # build looks, and the reason has to be findable afterwards without reading
  # half an hour of it. PIPESTATUS is make's own exit, not tee's.
  MLOG=/root/xui_ffbuild/make-$VER.log
  make -j"$JOBS" 2>&1 | tee "$MLOG"
  MRC=${PIPESTATUS[0]}
  # An assembler that cannot parse ffmpeg's own macros is a toolchain that is
  # behind, not a release this machine cannot have. Once per build, and only
  # when the failure is in a .asm: a newer nasm, then configure again — it
  # recorded which assembler to use and what it could do — and this same
  # release asked a second time.
  if [ "$MRC" != 0 ] && [ "$ASMFIXED" != 1 ] \
     && grep -qE '\.asm:[0-9]+: error:' "$MLOG"; then
    ASMFIXED=1
    if build_nasm; then
      echo "RETRY:$VER:nasm"
      # Said out loud. This put a compiler tool on the machine, outside apt,
      # and a screen that reports the ffmpeg it installed while staying quiet
      # about the assembler it had to build first is telling half of it.
      echo "assembler: $(nasm -v 2>/dev/null | head -1) compilado, o da distribuicao era antigo demais" >> /root/xui_ffbuild/notes
      if ./configure $OPTS > "$CLOG" 2>&1; then
        make -j"$JOBS" 2>&1 | tee "$MLOG"
        MRC=${PIPESTATUS[0]}
      fi
    fi
  fi
  if [ "$MRC" != 0 ]; then
    # The first compiler error, not the last line. make prints its own
    # "*** Error 1" summary after it, and with -j the tail is whichever
    # parallel job happened to finish last — neither says what broke.
    MERR=$(grep -m1 -E 'error:|fatal error:|No such file or directory' "$MLOG")
    [ -n "$MERR" ] || MERR=$(grep -m1 -E '^make.*Error' "$MLOG")
    echo "$VER|make|a compilacao parou: ${MERR:-sem mensagem}" >> /root/xui_ffbuild/why
    echo "SKIPPED:$VER:make"; continue
  fi

  mark PHASE:verify
  if ! ./ffmpeg -version > /dev/null 2>&1 || ! ./ffprobe -version > /dev/null 2>&1; then
    echo "$VER|verify|compilou e nao corre" >> /root/xui_ffbuild/why
    echo "SKIPPED:$VER:verify"; continue
  fi
  ./ffmpeg -version  | head -1
  ./ffprobe -version | head -1

  mark PHASE:wanted
  # Every encoder the panel's own transcode profiles name, asked of what was
  # just compiled. This is the other half of "is it safe to drop an option":
  # the panel's command line is proved below, but a configure option is a
  # capability, and a capability is asked for by name in the operator's
  # profiles. --enable-postproc gives the `pp` filter and nothing in the
  # panel's source mentions it; --enable-libfdk-aac gives an encoder, and a
  # profile saying -acodec libfdk_aac stops working the moment it goes.
  : > /root/xui_ffbuild/wanted
  WANTOUT=$(
D='.'
FM="$D/ffmpeg"
if [ ! -x "$FM" ]; then echo "WANT:none:no_binary"; exit 0; fi
ENC=$("$FM" -hide_banner -encoders 2>/dev/null)
DEC=$("$FM" -hide_banner -decoders 2>/dev/null)
for n in $(cat /root/xui_ffbuild/wanted_req 2>/dev/null); do
  if printf '%s\n' "$ENC" "$DEC" | awk '{print $2}' | grep -qx "$n"; then
    echo "WANT:$n:ok"
  else
    echo "WANT:$n:missing"
  fi
done
)
  printf '%s\n' "$WANTOUT" >> /root/xui_ffbuild/wanted
  WBAD=$(printf '%s\n' "$WANTOUT" | grep -c ':missing$' || true)
  if [ "${WBAD:-0}" != "0" ]; then
    printf '%s\n' "$WANTOUT" | grep ':missing$'
    echo "$VER|wanted|faltam $WBAD codec(s) que os perfis do painel pedem" >> /root/xui_ffbuild/why
    echo "SKIPPED:$VER:wanted"; continue
  fi

  mark PHASE:panel
  # The commands the panel actually builds, run against what was just
  # compiled, BEFORE the slot is touched — nothing that fails here is
  # installed. Same check the Diagnostics screen runs against a slot
  # afterwards, so the two can never drift apart.
  #
  # This is the gate a live REPLAY hit: ffmpeg 9.0.1 configured, built, ran,
  # had every codec the operator's profiles name, and turned down the panel's
  # timestamp command, because ffmpeg 9 no longer has -vsync. The binary is
  # fine; it is not one this panel can drive. That is a fact about the
  # release, so the release is what changes.

  : > /root/xui_ffbuild/panel
  PANELOUT=$(
D='.'
FM="$D/ffmpeg"; FP="$D/ffprobe"
PT=$(mktemp -d)
pok=0; pbad=0
emit() { echo "$1"; }
# The live outputs are asked apart from the rest, because the answer means
# something different. Measured on the operator's own machines: only the 4.0
# slot's build takes -segment_list_flags +live+delete. XUI's own 4.3 and 4.4
# do not have the flag either, so failing it is not a broken binary — it is a
# binary that cannot drive this panel's live channels, which is most of them,
# and is a thing to report rather than a thing to refuse.
lok=0; lbad=0
lcheck() {
  n=$1; shift
  if "$@" > "$PT/log" 2>&1; then
    lok=$((lok+1)); emit "live_ok:$n"
  else
    lbad=$((lbad+1)); emit "live_fail:$n"
    head -2 "$PT/log" | tr -cd '\11\12\40-\176' | sed 's/^/  /'
  fi
}
pcheck() {
  n=$1; shift
  if "$@" > "$PT/log" 2>&1; then
    pok=$((pok+1)); emit "ok:$n"
  else
    pbad=$((pbad+1)); emit "fail:$n"
    head -2 "$PT/log" | tr -cd '\11\12\40-\176' | sed 's/^/  /'
  fi
}
if [ ! -x "$FM" ] || [ ! -x "$FP" ]; then
  emit "fail:no_binaries"; emit "PANELCOUNT:0:1"; rm -rf "$PT"; exit 0
fi
# A two-second file made by the candidate itself, so nothing here depends on
# a sample being lying around.
if ! "$FM" -y -hide_banner -loglevel error \
     -f lavfi -i testsrc=size=320x240:rate=25:duration=2 \
     -f lavfi -i sine=frequency=1000:duration=2 \
     -c:v libx264 -c:a aac -shortest "$PT/a.mp4" > "$PT/mk" 2>&1; then
  emit "fail:no_test_file"
  head -2 "$PT/mk" | tr -cd '\11\12\40-\176' | sed 's/^/  /'
  emit "PANELCOUNT:0:1"; rm -rf "$PT"; exit 0
fi
"$FM" -y -hide_banner -loglevel error -i "$PT/a.mp4" -c copy "$PT/a.mkv" >/dev/null 2>&1
printf '1\n00:00:00,200 --> 00:00:01,800\nx\n\n' > "$PT/s.srt"
"$FM" -y -hide_banner -loglevel error -i "$PT/a.mp4" -i "$PT/s.srt" \
  -map 0 -map 1 -c copy -c:s srt "$PT/subs.mkv" >/dev/null 2>&1
pcheck probe "$FP" -probesize 5000000 -analyzeduration 5000000 \
  -i "$PT/a.mp4" -v quiet -print_format json -show_streams -show_format
for f in a.mp4 a.mkv; do
  pcheck "vod_copy_$f" "$FM" -y -nostdin -hide_banner -loglevel error \
    -err_detect ignore_err -fflags +genpts -async 1 -i "$PT/$f" \
    -map 0 -copy_unknown -vcodec copy -acodec copy \
    -movflags +faststart -dn -ignore_unknown -f mp4 "$PT/o_$f.mp4"
done
pcheck vod_x264 "$FM" -y -nostdin -hide_banner -loglevel error \
  -err_detect ignore_err -fflags +genpts -async 1 -i "$PT/a.mkv" \
  -map 0 -copy_unknown -vcodec libx264 -acodec aac \
  -movflags +faststart -dn -ignore_unknown -f mp4 "$PT/o_x.mp4"
pcheck timestamps "$FM" -y -nostdin -hide_banner -loglevel error \
  -err_detect ignore_err -i "$PT/a.mp4" -start_at_zero -copyts -vsync 0 \
  -correct_ts_overflow 0 -avoid_negative_ts disabled \
  -max_interleave_delta 0 -c copy -f mpegts "$PT/o.ts"
pcheck live "$FM" -y -nostdin -hide_banner -loglevel error \
  -err_detect ignore_err -fflags +genpts -async 1 -i "$PT/a.mp4" \
  -map 0 -copy_unknown -c copy -f mpegts "$PT/live.ts"
if [ -s "$PT/subs.mkv" ]; then
  pcheck subtitles "$FM" -y -nostdin -hide_banner -loglevel error \
    -err_detect ignore_err -i "$PT/subs.mkv" -map 0:s:0 "$PT/o.srt"
fi
pcheck mov_text "$FM" -y -nostdin -hide_banner -loglevel error \
  -i "$PT/a.mp4" -c:v copy -c:a copy -scodec mov_text -f mp4 "$PT/o_s.mp4"
# The four ways the panel puts a live channel on disk, copied out of its own
# source rather than paraphrased. The paraphrase is what let a stock 8.1.2
# into a slot and stopped every live channel on the server:
#
#   [(stream) segment muxer] Unable to parse "segment_list_flags" value "delete"
#   [out#0/segment] Could not write header (incorrect codec parameters ?)
#
# `-f segment -segment_time 4 -segment_format mpegts` is what this used to
# run, and it passes on any ffmpeg ever built. What the panel actually
# passes is below, flag for flag.
lcheck live_segment "$FM" -y -nostdin -hide_banner -loglevel error \
  -i "$PT/a.mp4" -map 0 -copy_unknown -c copy -individual_header_trailer 0 \
  -f segment -segment_format mpegts -segment_time 4 -segment_list_size 6 \
  -segment_format_options "mpegts_flags=+initial_discontinuity:mpegts_copyts=1" \
  -segment_list_type m3u8 -segment_list_flags +live+delete \
  -break_non_keyframes 1 \
  -segment_list "$PT/sl_.m3u8" "$PT/sl_%d.ts"
# The timeshift variant of it (xui.php:4691) differs by a start number.
lcheck delay_segment "$FM" -y -nostdin -hide_banner -loglevel error \
  -i "$PT/a.mp4" -map 0 -copy_unknown -c copy -individual_header_trailer 0 \
  -f segment -segment_format mpegts -segment_time 4 -segment_list_size 6 \
  -segment_start_number 0 \
  -segment_format_options "mpegts_flags=+initial_discontinuity:mpegts_copyts=1" \
  -segment_list_type m3u8 -segment_list_flags +live+delete \
  -segment_list "$PT/dl_.m3u8" "$PT/dl_%d.ts"
# And the other half of the same choice: seg_type 0 takes the hls muxer
# instead (xui.php:5677), with its own flag set.
lcheck live_hls "$FM" -y -nostdin -hide_banner -loglevel error \
  -i "$PT/a.mp4" -map 0 -copy_unknown -c copy -individual_header_trailer 0 \
  -f hls -hls_time 4 -hls_list_size 6 -hls_delete_threshold 4 \
  -hls_flags delete_segments+discont_start+omit_endlist \
  -break_non_keyframes 1 \
  -hls_segment_type mpegts -hls_segment_filename "$PT/hl_%d.ts" "$PT/hl_.m3u8"
lcheck delay_hls "$FM" -y -nostdin -hide_banner -loglevel error \
  -i "$PT/a.mp4" -map 0 -copy_unknown -c copy -individual_header_trailer 0 \
  -f hls -hls_time 4 -hls_list_size 6 -hls_delete_threshold 4 -start_number 0 \
  -hls_flags delete_segments+discont_start+omit_endlist \
  -hls_segment_type mpegts -hls_segment_filename "$PT/dh_%d.ts" "$PT/dh_.m3u8"
# The deprecation notices the panel's own -loglevel error hides. These are not
# failures; they are how much road is left.
for o in "-vsync 0" "-async 1"; do
  W=$("$FM" -y -nostdin -hide_banner -loglevel warning -i "$PT/a.mp4" $o \
      -c copy -f null - 2>&1 | grep -i 'deprecat\|will be removed' | head -1 \
      | tr -cd '\40-\176' | cut -c1-70)
  [ -n "$W" ] && emit "warn:$o: $W"
done
emit "VERSION:$("$FM" -version 2>/dev/null | head -1 | tr -cd '\40-\176' | cut -c1-90)"
# Accepted is not the same as working. A `delete` that parses and never
# unlinks fills the disk quietly, which is worse than one that refuses — so
# the same file is segmented twice, with the flag and without it, and what
# is left on disk is counted. Self-calibrating: no threshold to be wrong
# about, just fewer files or not.
DA="$PT/da"; DB="$PT/db"; mkdir -p "$DA" "$DB"
"$FM" -y -hide_banner -loglevel error -f lavfi \
  -i testsrc=size=160x120:rate=25:duration=8 -c:v libx264 -g 25 \
  "$PT/long.mp4" > /dev/null 2>&1
if [ ! -s "$PT/long.mp4" ]; then
  emit "DELETE:no_test_file"
elif ! "$FM" -y -hide_banner -loglevel error -i "$PT/long.mp4" -c copy \
     -f segment -segment_format mpegts -segment_time 1 -segment_list_size 3 \
     -segment_list_type m3u8 -segment_list_flags +live+delete \
     -segment_list "$DB/l.m3u8" "$DB/%d.ts" > /dev/null 2>&1; then
  emit "DELETE:refused"
else
  "$FM" -y -hide_banner -loglevel error -i "$PT/long.mp4" -c copy \
    -f segment -segment_format mpegts -segment_time 1 -segment_list_size 3 \
    -segment_list_type m3u8 -segment_list_flags +live \
    -segment_list "$DA/l.m3u8" "$DA/%d.ts" > /dev/null 2>&1
  NA=$(ls "$DA"/*.ts 2>/dev/null | wc -l)
  NB=$(ls "$DB"/*.ts 2>/dev/null | wc -l)
  if [ "${NA:-0}" -lt 2 ]; then emit "DELETE:no_segments"
  elif [ "${NB:-0}" -lt "${NA:-0}" ]; then emit "DELETE:works:$NA:$NB"
  else emit "DELETE:inert:$NA:$NB"; fi
fi
emit "LIVECOUNT:$lok:$lbad"
emit "PANELCOUNT:$pok:$pbad"
rm -rf "$PT"
)
  printf '%s\n' "$PANELOUT" >> /root/xui_ffbuild/panel
  PBAD=$(printf '%s\n' "$PANELOUT" | sed -n 's/^PANELCOUNT:[0-9]*:\([0-9]*\)$/\1/p' | tail -1)
  # The live output this panel is actually set to. Passing every ordinary
  # command and failing this one is exactly what put a build in a slot and
  # stopped every live channel on the server, so it is part of the gate now.
  ST=$(cat /root/xui_ffbuild/segtype 2>/dev/null)
  case "$ST" in
    0) LNEED="live_hls delay_hls" ;;
    1) LNEED="live_segment delay_segment" ;;
    *)
      # Not a default and not a shrug. Without it there is no telling whether
      # what was built can carry a live channel on this panel, and a slot is
      # not a place to put something nobody can answer that about.
      fail "nao sei a que saida live este painel esta configurado" ;;
  esac
  LBAD=""
  for n in $LNEED; do
    printf '%s\n' "$PANELOUT" | grep -qx "live_ok:$n" || LBAD="$LBAD $n"
  done
  if [ -n "$LBAD" ]; then
    echo "$VER|panel|nao serve o live deste painel (segment_type=$ST):$LBAD" >> /root/xui_ffbuild/why
    echo "SKIPPED:$VER:live"; continue
  fi
  # And the case the command line cannot show: a `delete` that is accepted
  # and never unlinks anything. It passes every check above and fills the
  # disk of a live server in silence, which is worse than refusing outright.
  if [ "$ST" = 1 ]; then
    DR=$(printf '%s\n' "$PANELOUT" | sed -n 's/^DELETE:\([a-z_]*\).*/\1/p' | tail -1)
    if [ "$DR" = inert ]; then
      echo "$VER|panel|a flag delete e aceite mas nao apaga os segmentos" >> /root/xui_ffbuild/why
      echo "SKIPPED:$VER:delete"; continue
    fi
  fi
  if [ "${PBAD:-1}" != 0 ]; then
    # Named, not counted. "refuses 1 command" sends you to the log; "refuses
    # timestamps" is the whole answer, and it is the line the screen shows.
    PF=$(printf '%s\n' "$PANELOUT" | sed -n 's/^fail:\(.*\)/\1/p' | tr '\n' ' ')
    echo "$VER|panel|recusa ${PBAD:-?} comando(s) do painel: ${PF:-?}" >> /root/xui_ffbuild/why
    echo "SKIPPED:$VER:panel"; continue
  fi

  GOTIT=1
done
# Out of the version loop. Every release that could not be configured, could
# not be built, or could not drive this panel has been passed over with its
# reason written down; running out of them is the failure.
[ "$GOTIT" = 1 ] || fail "nenhuma versao do ffmpeg serve este painel"
printf '%s\n' "${MISS[@]}" > /root/xui_ffbuild/missing

mark PHASE:install
mkdir -p "$DEST"
# ffmpeg.real ahead of ffmpeg: for the moment between the two copies the
# wrapper would otherwise be in the slot with nothing to exec.
BINS="ffmpeg ffprobe"
[ "$WRAP" = 1 ] && BINS="ffmpeg.real ffmpeg ffprobe"
for b in $BINS; do
  # Whatever was here first, kept once and never overwritten. The rule used
  # to be "keep it only if it does not run", which was meant to stop a second
  # build burying the good copy the first one made — and meant that a working
  # original was replaced with no way back. That is how an estate of servers
  # lost the binaries the panel shipped with, and no reasoning about which
  # copy is worth keeping is worth that.
  if [ -e "$DEST/$b" ] && [ ! -e "$DEST/$b.orig" ]; then
    cp -p "$DEST/$b" "$DEST/$b.orig"
  fi
  # And .broken keeps its own meaning: evidence of one that did not run.
  if [ -e "$DEST/$b" ] && [ ! -e "$DEST/$b.broken" ] \
     && [ -z "$("$DEST/$b" -version 2>/dev/null | head -1)" ]; then
    cp -p "$DEST/$b" "$DEST/$b.broken"
  fi
  # Beside and renamed over: the panel may be running the one in the slot,
  # and writing over a busy binary fails where a rename does not.
  cp "./$b" "$DEST/.$b.new" || fail "copiar $b"
  chmod 0755 "$DEST/.$b.new"; chown xui:xui "$DEST/.$b.new" 2>/dev/null
  mv -f "$DEST/.$b.new" "$DEST/$b" || fail "por $b na slot"
done
V=$("$DEST/ffprobe" -version 2>/dev/null | head -1 | tr -cd '\11\40-\176')
[ -n "$V" ] || fail "esta na slot e nao corre de la"
echo "DONE:$V" > /root/xui_ffbuild/state
