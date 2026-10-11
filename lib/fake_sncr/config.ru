# lib/fake_sncr/config.ru
# SNCR SIMULADO do compose de dev (ADR 0034). Nunca em produção.
# FAKE_SNCR_EXHAUSTED_UFS e FAKE_SNCR_MISMATCH_DOCUMENTS (vírgulas) simulam
# faixa esgotada e inscrição divergente.
require_relative "app"

abort "fake-sncr nunca sobe em produção" if (ENV["RAILS_ENV"] || ENV["RACK_ENV"]).to_s == "production"

app = FakeSncr::App.new
app.exhausted_ufs = ENV.fetch("FAKE_SNCR_EXHAUSTED_UFS", "").split(",").map(&:strip).reject(&:empty?)
app.mismatch_documents = ENV.fetch("FAKE_SNCR_MISMATCH_DOCUMENTS", "").split(",").map(&:strip).reject(&:empty?)
run app
