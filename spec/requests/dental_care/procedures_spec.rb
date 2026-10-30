require "rails_helper"

# Módulo 28 (ADR 0046; contrato §16 O5, O21; Ruling 6): busca de procedimento
# SIGTAP da consulta odontológica, com o local e a quantidade da FAO. Termo só
# no corpo; sem dado pessoal e sem trilha.
RSpec.describe "Saúde bucal — busca de procedimento", type: :request do
  let!(:city) { dental_city! }
  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }

  def body = JSON.parse(response.body)
  def search(q) = json_post("/dental/procedures/search", q: q)
  def found(code) = body.fetch("procedures").find { |p| p["sigtap"] == code }

  it "por nome (sem acento): local e máximo da lista do LEDI, auxiliar e prótese" do
    sign_in_as(dentist)
    search("restauracao de dente permanente")
    expect(response).to have_http_status(:ok)
    expect(found("0307010031")).to eq("sigtap" => "0307010031", "name" => "RESTAURAÇÃO DE DENTE PERMANENTE ANTERIOR COM RESINA COMPOSTA",
                                      "locations" => %w[tooth face], "max_quantity" => 32, "auxiliary_allowed" => false,
                                      "prosthesis" => false)
    expect(body["procedures"].map { |p| p["sigtap"] }).to all(start_with("0307010"))
  end

  it "por código: sextante, arcada, prótese, procedimento do TSB/ASB e fora da lista (mouth, 1)" do
    sign_in_as(dentist)
    search("0307030059")
    expect(found("0307030059")).to include("locations" => %w[sextant], "max_quantity" => 6, "auxiliary_allowed" => true)
    search("0701070129")
    expect(found("0701070129")).to include("locations" => %w[arch], "max_quantity" => 2, "prosthesis" => true)
    search("0101020074")
    expect(found("0101020074")).to include("locations" => %w[mouth], "max_quantity" => 1, "auxiliary_allowed" => true, "prosthesis" => false)
  end

  it "nunca devolve o procedimento proibido na FAO" do
    sign_in_as(dentist)
    search("0301040079")
    expect(body).to eq("procedures" => [])
    search("escuta inicial")
    expect(body["procedures"].map { |p| p["sigtap"] }).not_to include("0301040079")
  end

  it "termo vazio, ausente ou não texto → lista vazia; até 20" do
    sign_in_as(dentist)
    [ "", nil, 123, { "a" => 1 } ].each do |q|
      search(q)
      expect([ response.status, body ]).to eq([ 200, { "procedures" => [] } ])
    end
    search("0")
    expect(body["procedures"].size).to be <= 20
  end

  it "TSB/ASB busca; médico e recepção → 403 missing_role; interruptor desligado → 403 feature_disabled" do
    sign_in_as(auxiliary!(unit))
    search("selante")
    expect(found("0101020066")).to include("auxiliary_allowed" => true, "locations" => %w[tooth face])
    sign_in_as(doctor!(unit))
    search("selante")
    expect([ response.status, body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(reception!)
    search("selante")
    expect([ response.status, body ]).to eq([ 403, { "error" => "missing_role" } ])
    Platform::Features.set!(city: city, key: "dental_care", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(dentist)
    search("selante")
    expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "dental_care" } ])
  end

  it "o termo na query não vale; sem trilha nem evento" do
    sign_in_as(dentist)
    expect { post "/dental/procedures/search?q=selante", headers: { "CONTENT_TYPE" => "application/json" }, params: "{}" }
      .not_to change(DomainEvent, :count)
    expect(body).to eq("procedures" => [])
  end
end
