#!/usr/bin/env bash

. ./path.sh || exit 1;

if [ $# != 2 ]; then
  echo "Usage: $0 <audio-path> <text-path>"
  echo " $0 /export/corpora/LDC03S04 /export/corpora/LDC03T19"
  exit 1;
fi

hkust_audio_dir=$1
hkust_text_dir=$2

train_dir=data/local/train
dev_dir=data/local/dev
train_dev=train_dev
train_nodev=train_nodev

nj=16

mkdir -p $train_dir
mkdir -p $dev_dir

#data directory check
if [ ! -d $hkust_audio_dir ] || [ ! -d $hkust_text_dir ]; then
  echo "Error: $0 requires two directory arguments"
  exit 1;
fi

#find sph audio file for train dev resp.
find $hkust_audio_dir -iname "*.sph" | grep -i "audio/train" > $train_dir/sph.flist || exit 1;
find $hkust_audio_dir -iname "*.sph" | grep -i "audio/dev" > $dev_dir/sph.flist || exit 1;

n=`cat $train_dir/sph.flist $dev_dir/sph.flist | wc -l`
[ $n -ne 897 ] && \
  echo Warning: expected 897 data data files, found $n

#Transcriptions preparation

#collect all trans, convert encodings to utf-8,
find $hkust_text_dir -iname "*.txt" | grep -i "trans/train" | xargs cat |\
  iconv -f GBK -t UTF-8 | perl -e '
    while (<STDIN>) {
      @A = split(" ", $_);
      if (@A <= 1) { next; }
      if ($A[0] eq "#") { $utt_id = $A[1]; }
      if (@A >= 3) {
        $A[2] =~ s:^([AB])\:$:$1:;
        printf "%s-%s-%06.0f-%06.0f", $utt_id, $A[2], 100*$A[0] + 0.5, 100*$A[1] + 0.5;
        for($n = 3; $n < @A; $n++) { print " $A[$n]" };
        print "\n";
      }
    }
  ' | sort -k1 > $train_dir/transcripts.txt || exit 1;

find $hkust_text_dir -iname "*.txt" | grep -i "trans/dev" | xargs cat |\
  iconv -f GBK -t UTF-8 | perl -e '
    while (<STDIN>) {
      @A = split(" ", $_);
      if (@A <= 1) { next; }
      if ($A[0] eq "#") { $utt_id = $A[1]; }
      if (@A >= 3) {
        $A[2] =~ s:^([AB])\:$:$1:;
        printf "%s-%s-%06.0f-%06.0f", $utt_id, $A[2], 100*$A[0] + 0.5, 100*$A[1] + 0.5;
        for($n = 3; $n < @A; $n++) { print " $A[$n]" };
        print "\n";
      }
    }
  ' | sort -k1  > $dev_dir/transcripts.txt || exit 1;

#transcripts normalization and segmentation
cat $train_dir/transcripts.txt |\
  sed -e 's/<foreign language=\"[a-zA-Z]\+\">/ /g' |\
  sed -e 's/<\/foreign>/ /g' |\
  sed -e 's/<noise>\(.\+\)<\/noise>/\1/g' |\
  sed -e 's/<\/noise>//g' |\
  sed -e 's/((\([^)]\{0,\}\)))/\1/g' |\
  sed -e 's/((\([^)]\{0,\}\)))/\1/g' |\
  awk '{if (NF > 1) print $0;}' |\
  local/hkust_normalize.pl |\
  awk '{if (NF > 0) print $0;}' > $train_dir/text || exit 1;

cat $dev_dir/transcripts.txt |\
  sed -e 's/<foreign language=\"[a-zA-Z]\+\">/ /g' |\
  sed -e 's/<\/foreign>/ /g' |\
  sed -e 's/<noise>\(.\+\)<\/noise>/\1/g' |\
  sed -e 's/<\/noise>//g' |\
  sed -e 's/((\([^)]\{0,\}\)))/\1/g' |\
  sed -e 's/((\([^)]\{0,\}\)))/\1/g' |\
  awk '{if (NF > 1) print $0;}' |\
  local/hkust_normalize.pl |\
  awk '{if (NF > 0) print $0;}' > $dev_dir/text || exit 1;

# some data is corrupted. Delete them
cat $train_dir/text | grep -v 20040527_210939_A901153_B901154-A-035691-035691 | egrep -v "A:|B:" > tmp
mv tmp $train_dir/text || exit 1;

#Make segment files from transcript
#segments file format is: utt-id side-id start-time end-time, e.g.:
#sw02001-A_000098-001156 sw02001-A 0.98 11.56

awk '{ segment=$1; split(segment,S,"-"); side=S[2]; audioname=S[1];startf=S[3];endf=S[4];
   print segment " " audioname "-" side " " startf/100 " " endf/100}' <$train_dir/text > $train_dir/segments
awk '{name = $0; gsub(".sph$","",name); gsub(".*/","",name); print(name " " $0)}' $train_dir/sph.flist > $train_dir/sph.scp

awk '{ segment=$1; split(segment,S,"-"); side=S[2]; audioname=S[1];startf=S[3];endf=S[4];
   print segment " " audioname "-" side " " startf/100 " " endf/100}' <$dev_dir/text > $dev_dir/segments
awk '{name = $0; gsub(".sph$","",name); gsub(".*/","",name); print(name " " $0)}' $dev_dir/sph.flist > $dev_dir/sph.scp

bash tools/sph2wav.sh --nj ${nj} $train_dir/sph.scp $train_dir/segments $train_dir/wav.scp
bash tools/sph2wav.sh --nj ${nj} $dev_dir/sph.scp $dev_dir/segments $dev_dir/wav.scp

#side A - channel 1, side B - channel 2

# this file reco2file_and_channel maps recording-id (e.g. sw02001-A)
# to the file name sw02001 and the A, e.g.
# sw02001-A  sw02001 A
# In this case it's trivial, but in other corpora the information might
# be less obvious.  Later it will be needed for ctm scoring.
cat $train_dir/wav_ori.scp | awk '{print $1}' | \
  perl -ane '$_ =~ m:^(\S+)-([AB])$: || die "bad label $_"; print "$1-$2 $1 $2\n"; ' \
  > $train_dir/reco2file_and_channel || exit 1;
cat $dev_dir/wav_ori.scp | awk '{print $1}' | \
  perl -ane '$_ =~ m:^(\S+)-([AB])$: || die "bad label $_"; print "$1-$2 $1 $2\n"; ' \
  > $dev_dir/reco2file_and_channel || exit 1;


cat $train_dir/segments | awk '{spk=substr($1,1,33); print $1 " " spk}' > $train_dir/utt2spk || exit 1;
cat $train_dir/utt2spk | sort -k 2 | tools/utt2spk_to_spk2utt.pl > $train_dir/spk2utt || exit 1;

cat $dev_dir/segments | awk '{spk=substr($1,1,33); print $1 " " spk}' > $dev_dir/utt2spk || exit 1;
cat $dev_dir/utt2spk | sort -k 2 | tools/utt2spk_to_spk2utt.pl > $dev_dir/spk2utt || exit 1;

mkdir -p data/train data/dev

for f in spk2utt utt2spk wav.scp text segments reco2file_and_channel; do
  cp data/local/train/$f data/train/$f || exit 1;
done

for f in spk2utt utt2spk wav.scp text segments reco2file_and_channel; do
  cp data/local/dev/$f data/dev/$f || exit 1;
done

tools/subset_data_dir.sh --first data/train 4001 data/${train_dev}
n=$(($(wc -l < data/train/segments) - 4001))
tools/subset_data_dir.sh --last data/train ${n} data/${train_nodev}

echo "$0: HKUST data preparation succeeded"
exit 0
