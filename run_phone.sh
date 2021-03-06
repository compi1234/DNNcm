#!/bin/bash

. ~/.bashrc
. ./cmd.sh 
[ -f path.sh ] && . ./path.sh
set -e

stage=0

minlmwt=1
maxlmwt=25
expname=$1
feats_nj=80
train_nj=80
decode_nj=30

echo ============================================================================
echo "                Data & Lexicon & Language Preparation                     "
echo ============================================================================

datadir="data_phone"
expdir="exp_phone"
mfccdir="mfcc_phone"

lmdir="${datadir}/lmdir"
langdir="${datadir}/lang"
localdir="${datadir}/local"
dictdir="${datadir}/local/dict"
resourcedir="resources"
tempdir="temp"

# Acoustic model parameters

numLeavesTri1=7500
numGaussTri1=40000
numLeavesMLLT=7500
numGaussMLLT=40000
numLeavesSAT=7500
numGaussSAT=40000
numGaussUBM=800
numLeavesSGMM=10000
numGaussSGMM=20000

if [ $stage -le 1 ]; then

utils/prepare_lang.sh --sil_prob 0.5 --position-dependent-phones true --num-sil-states 3 ${dictdir} "SPN" ${localdir}/lang_tmp ${langdir}
ngram-count -order 3 -text ${resourcedir}/phone_LM_train -lm ${resourcedir}/LM_NL_phone
gzip -f ${resourcedir}/LM_NL_phone && cp -r ${datadir}/lang ${datadir}/lang_test
utils/format_lm.sh ${datadir}/lang ${resourcedir}/LM_NL_phone.gz ${datadir}/local/dict/lexicon.txt ${datadir}/lang_test || exit 1

fi

if [ $stage -le 2 ]; then

# Now make MFCC and FBANK features.
echo ============================================================================
echo "                     MFCC and FBANK features                             "
echo ============================================================================

for x in train_cgn_tr90 train_cgn_cv10 ; do
  steps/make_mfcc.sh --cmd "$train_cmd" --nj $feats_nj ${datadir}/$x ${expdir}/make_mfcc/$x $mfccdir
  steps/compute_cmvn_stats.sh ${datadir}/$x ${expdir}/make_mfcc/$x $mfccdir
done

fi

traindatadir="${datadir}/train_cgn_tr90"
testdatadir="${datadir}/train_cgn_cv10"

if [ $stage -le 3 ]; then

echo ============================================================================
echo "                     MonoPhone Training & Decoding                        "
echo ============================================================================

steps/train_mono.sh --nj "$train_nj" --cmd "$train_cmd" ${traindatadir}  ${langdir} ${expdir}/mono

fi

if [ $stage -le 4 ]; then

echo ============================================================================
echo "           tri1 : Deltas + Delta-Deltas Training & Decoding               "
echo ============================================================================

steps/align_si.sh --nj "$train_nj" --cmd "$train_cmd" ${traindatadir} ${langdir} ${expdir}/mono ${expdir}/mono_ali

steps/train_deltas.sh --cmd "$train_cmd" $numLeavesTri1 $numGaussTri1 ${traindatadir} ${langdir} ${expdir}/mono_ali ${expdir}/tri1

# utils/mkgraph.sh ${langdir} ${expdir}/tri1 ${expdir}/tri1/graph

# steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" --scoring-opts "--min-lmwt $minlmwt --max-lmwt $maxlmwt" ${expdir}/tri1/graph ${testdatadir} ${expdir}/tri1/decode_test

steps/align_si.sh --nj "$train_nj" --cmd "$train_cmd" ${traindatadir} ${langdir} ${expdir}/tri1 ${expdir}/tri1_ali

fi

if [ $stage -le 5 ]; then

echo ============================================================================
echo "                 tri2 : LDA + MLLT Training & Decoding                    "
echo ============================================================================

steps/train_lda_mllt.sh --cmd "$train_cmd" --splice-opts "--left-context=3 --right-context=3" $numLeavesMLLT $numGaussMLLT ${traindatadir} ${langdir} ${expdir}/tri1_ali ${expdir}/tri2

# utils/mkgraph.sh ${langdir} ${expdir}/tri2 ${expdir}/tri2/graph

# steps/decode.sh --nj "$decode_nj" --cmd "$decode_cmd" --scoring-opts "--min-lmwt $minlmwt --max-lmwt $maxlmwt" ${expdir}/tri2/graph ${testdatadir} ${expdir}/tri2/decode_test

steps/align_si.sh --nj "$train_nj" --cmd "$train_cmd" ${traindatadir} ${langdir} ${expdir}/tri2 ${expdir}/tri2_ali

fi

if [ $stage -le 6 ]; then

echo ============================================================================
echo "              tri3 : LDA + MLLT + SAT Training & Decoding                 "
echo ============================================================================

steps/train_sat.sh --cmd "$train_cmd" $numLeavesSAT $numGaussSAT ${traindatadir} ${langdir} ${expdir}/tri2_ali ${expdir}/tri3

utils/mkgraph.sh ${langdir}_test ${expdir}/tri3 ${expdir}/tri3/graph

steps/decode_fmllr.sh --nj  "$decode_nj" --cmd "$decode_cmd" --scoring-opts "--min-lmwt $minlmwt --max-lmwt $maxlmwt" ${expdir}/tri3/graph ${testdatadir} ${expdir}/tri3/decode_test

steps/align_fmllr.sh --nj 20 --cmd "$train_cmd" ${traindatadir} ${langdir} ${expdir}/tri3 ${expdir}/tri3_train_ali

steps/align_fmllr.sh --nj 20 --cmd "$train_cmd" ${testdatadir} ${langdir} ${expdir}/tri3 ${expdir}/tri3_test_ali

fi

echo "GMM-HMM models and the required alignments are ready. Let's proceed with the DNN training..."

echo ============================================================================
echo "              DNN preparation & hi-res feature extraction                 "
echo ============================================================================

if [ $stage -le 7 ]; then

  for data in train_cgn_tr90 train_cgn_cv10; do
    utils/copy_data_dir.sh ${datadir}/$data ${datadir}/${data}_hires
    steps/make_mfcc.sh --nj 40 --mfcc-config conf/mfcc_hires.conf \
      --cmd "$train_cmd" ${datadir}/${data}_hires ${expdir}/make_hires/$data $mfccdir || exit 1;
    steps/compute_cmvn_stats.sh ${datadir}/${data}_hires ${expdir}/make_hires/$data $mfccdir || exit 1;
  done
fi


if [ $stage -le 8 ]; then
  # We need to build a small system just because we need the LDA+MLLT transform
  # to train the diag-UBM on top of.  We align the si84 data for this purpose.

  steps/align_fmllr.sh --nj 40 --cmd "$train_cmd" \
    ${datadir}/train_cgn_tr90 ${datadir}/lang ${expdir}/tri3 ${expdir}/nnet2_online/tri3_ali
fi

if [ $stage -le 9 ]; then
  # Train a small system just for its LDA+MLLT transform.  We use --num-iters 13
  # because after we get the transform (12th iter is the last), any further
  # training is pointless.
  steps/train_lda_mllt.sh --cmd "$train_cmd" --num-iters 13 \
    --realign-iters "" \
    --splice-opts "--left-context=3 --right-context=3" \
    5000 10000 ${datadir}/train_cgn_tr90_hires ${datadir}/lang \
     ${expdir}/nnet2_online/tri3_ali ${expdir}/nnet2_online/tri4
fi

if [ $stage -le 10 ]; then
  mkdir -p ${expdir}/nnet2_online

  steps/online/nnet2/train_diag_ubm.sh --cmd "$train_cmd" --nj 30 \
     --num-frames 400000 ${datadir}/train_cgn_tr90_hires 256 ${expdir}/nnet2_online/tri4 ${expdir}/nnet2_online/diag_ubm
fi

if [ $stage -le 11 ]; then
  # even though $nj is just 10, each job uses multiple processes and threads.
  steps/online/nnet2/train_ivector_extractor.sh --cmd "$train_cmd" --nj 10 \
    ${datadir}/train_cgn_tr90_hires ${expdir}/nnet2_online/diag_ubm ${expdir}/nnet2_online/extractor || exit 1;
fi

if [ $stage -le 12 ]; then
  # We extract iVectors on all the train_cgn_tr90 data, which will be what we
  # train the system on.

  # having a larger number of speakers is helpful for generalization, and to
  # handle per-utterance decoding well (iVector starts at zero).
  steps/online/nnet2/copy_data_dir.sh --utts-per-spk-max 2 ${datadir}/train_cgn_tr90_hires \
    ${datadir}/train_cgn_tr90_hires_max2

  steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 30 \
    ${datadir}/train_cgn_tr90_hires_max2 ${expdir}/nnet2_online/extractor ${expdir}/nnet2_online/ivectors_train_cgn_tr90 || exit 1;
fi

if [ $stage -le 13 ]; then

  for data in train_cgn_tr90 train_cgn_cv10; do
    steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 8 \
      ${datadir}/${data}_hires ${expdir}/nnet2_online/extractor ${expdir}/nnet2_online/ivectors_${data}
  done

fi

echo "Preparations for the DNN training completed..."

echo ============================================================================
echo "                           DNN training                                   "
echo ============================================================================

if [ $stage -le 14 ]; then

  dir=${expdir}/nnet2_online/nnet_ms_a
  train_stage=-10
  exit_train_stage=-100
  use_gpu=true
  if $use_gpu; then
    if ! cuda-compiled; then
      cat <<EOF && exit 1 
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA 
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.  Otherwise, call this script with --use-gpu false
EOF
    fi
    parallel_opts="--gpu 1" 
    num_threads=1
    minibatch_size=512
    # the _a is in case I want to change the parameters.
  else
    num_threads=16
    minibatch_size=128
    parallel_opts="--num-threads $num_threads" 
  fi

  steps/nnet2/train_multisplice_accel2.sh --stage $train_stage \
    --exit-stage $exit_train_stage \
    --num-epochs 8 --num-jobs-initial 2 --num-jobs-final 14 \
    --num-hidden-layers 4 \
    --splice-indexes "layer0/-1:0:1 layer1/-2:1 layer2/-4:2" \
    --feat-type raw \
    --online-ivector-dir ${expdir}/nnet2_online/ivectors_train_cgn_tr90 \
    --cmvn-opts "--norm-means=false --norm-vars=false" \
    --num-threads "$num_threads" \
    --minibatch-size "$minibatch_size" \
    --parallel-opts "$parallel_opts" \
    --io-opts "--max-jobs-run 12" \
    --initial-effective-lrate 0.005 --final-effective-lrate 0.0005 \
    --cmd "$decode_cmd" \
    --pnorm-input-dim 2000 \
    --pnorm-output-dim 250 \
    --mix-up 12000 \
    ${datadir}/train_cgn_tr90_hires ${datadir}/lang ${expdir}/tri3_train_ali $dir  || exit 1;
fi

if [ $stage -le 15 ]; then
  # this does offline decoding that should give the same results as the real
  # online decoding.
  dir=${expdir}/nnet2_online/nnet_ms_a
  graph_dir=${expdir}/tri3/graph
  # use already-built graphs.
  steps/nnet2/decode.sh --nj 8 --cmd "$decode_cmd" \
     --online-ivector-dir ${expdir}/nnet2_online/ivectors_train_cgn_cv10 \
     $graph_dir ${datadir}/train_cgn_cv10_hires $dir/decode || exit 1;
fi
