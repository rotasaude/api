# PSC SIMULADO do compose de dev (ADR 0032; Task 18). Nunca em produção: a
# imagem de produção não sobe este arquivo. e-CPF de teste da AC de dev do
# signer (volume signer-dev-pki); FAKE_PSC_ABSENT_CPFS (vírgulas) simula
# profissional sem certificado.
require_relative "app"

pki = FakePsc::Pki.load(ENV.fetch("SIGNER_DEV_PKI_DIR"))
app = FakePsc::App.new(pki: pki)
app.absent_cpfs = ENV.fetch("FAKE_PSC_ABSENT_CPFS", "").split(",").map(&:strip).reject(&:empty?)
run app
