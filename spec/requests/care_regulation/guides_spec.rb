require "rails_helper"
require "pdf/reader"

# Módulo 26a, Task 12 (ADR 0044; contrato §3, §13 G6, G8; plano do api, Desvio
# 13): GET /regulation/requests/:id/guide.pdf — a autora, o profissional com
# vínculo ativo na unidade solicitante e o regulador leem; qualquer outro (e o
# rascunho) recebe 404. Trilha por pessoa, sem cache, nome do arquivo com o id
# inteiro e sem dado pessoal; nada pessoal na URL nem no log.
RSpec.describe "Regulação — guia de encaminhamento", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before { travel_to now }

  let!(:city) { regulation_city! }
  let!(:profile) { city_profile! }
  let(:unit) { create_unit("UBS Solicitante #{SecureRandom.hex(2)}") }
  let(:author) { doctor!(unit) }
  let(:justification) { "Justificativa-sigilosa-da-guia com os exames anexados" }
  let!(:regulation) { regulation_request!(unit: unit, doctor: author, justification: justification) }

  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at)
  def guide(id = regulation.id, params: {}) = get("/regulation/requests/#{id}/guide.pdf", params: params)
  def pdf_text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ").gsub(/\s+/, " ")

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  it "a autora: 200 application/pdf, sem cache, nome com o id inteiro e sem dado pessoal; uma trilha por pessoa" do
    sign_in_as(author)
    log = capture_log { expect { guide }.to change { viewed.count }.by(1) }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body).to start_with("%PDF")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    disposition = response.headers["Content-Disposition"]
    expect(disposition).to start_with("attachment")
    expect(disposition).to include("guia-regulacao-#{regulation.id}.pdf")
    expect(disposition).not_to include(regulation.patient.display_name.parameterize)
    expect(disposition[/filename="?([^";]+)/, 1]).to match(/\A[A-Za-z0-9._-]+\z/)
    expect(viewed.last.payload).to eq("patient_id" => regulation.patient_id, "user_id" => author.id, "access" => "regulation",
                                      "reason_code" => nil, "person_ref" => "patient:#{regulation.patient_id}")
    expect(pdf_text).to include("Guia de encaminhamento", "Cardiologia", justification)
    expect(log).not_to include(justification)
    expect(log).not_to include(regulation.patient.display_name)
    expect(log).not_to include(regulation.patient.cpf)
  end

  it "colega com vínculo ativo na unidade solicitante: 200" do
    sign_in_as(doctor!(unit))
    guide
    expect(response).to have_http_status(:ok)
  end

  it "o regulador: 200" do
    sign_in_as(care_regulator!)
    guide
    expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
  end

  it "profissional de outra unidade → 404 sem revelar a existência, e nenhuma trilha" do
    sign_in_as(doctor!(create_unit("Outra UBS #{SecureRandom.hex(2)}")))
    expect { guide }.not_to(change { viewed.count })
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    other = json_body
    guide(SecureRandom.uuid)
    expect(json_body).to eq(other)
  end

  it "colega com o vínculo encerrado na unidade → 404" do
    colleague = doctor!(unit)
    colleague.professional.links.active.find_by!(health_unit: unit).update!(ended_at: Time.current, ended_by_user: regulation_admin!)
    sign_in_as(colleague)
    guide
    expect(response).to have_http_status(:not_found)
  end

  it "administrador municipal → 404" do
    sign_in_as(regulation_admin!)
    guide
    expect(response).to have_http_status(:not_found)
  end

  it "rascunho (mesmo para a autora e o regulador), id inexistente ou malformado → 404, sem trilha" do
    draft = regulation_request!(status: "draft", unit: unit, doctor: author)
    sign_in_as(author)
    [ draft.id, SecureRandom.uuid, "xyz" ].each do |id|
      expect { guide(id) }.not_to(change { viewed.count })
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end
    sign_in_as(care_regulator!)
    guide(draft.id)
    expect(response).to have_http_status(:not_found)
  end

  it "query extra → 422 invalid_request com o NOME da chave; sem trilha" do
    sign_in_as(author)
    expect { guide(params: { cpf: regulation.patient.cpf }) }.not_to(change { viewed.count })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cpf" } ])
    expect(response.body).not_to include(regulation.patient.cpf)
  end

  it "imprime o pedido já decidido (devolvido) para a unidade" do
    returned = CareRegulation::Decide.call(request: regulation, decision: "return", reason: "Faltam exames anexos ao pedido",
                                           version: regulation.version, by: care_regulator!)
    raise "devolução recusada: #{returned.reason}" if returned.failure?

    sign_in_as(author)
    guide
    expect(response).to have_http_status(:ok)
  end

  it "sem sessão → 401" do
    guide
    expect(response).to have_http_status(:unauthorized)
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(author)
    guide
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
  end
end
