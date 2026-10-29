require "rails_helper"
require "csv"

# Módulo 26a, Task 11 (ADR 0044; contrato §8, §13 G8; overlay): GET
# /regulation/exports/state.csv — só o care_regulator, sem cache, nome do
# arquivo sem dado pessoal, trilha de lista com os ids.
RSpec.describe "Regulação — CSV do estado", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before { travel_to now }

  let!(:city) { regulation_city! }
  let(:regulator) { care_regulator! }
  let!(:external) do
    regulation_request!.tap do |request|
      marked = CareRegulation::MarkExternal.call(request: request, system: "sisreg", number: "123456789", version: request.version,
                                                 by: regulator)
      raise "marcação recusada: #{marked.reason}" if marked.failure?
    end.reload
  end
  let!(:waiting) { regulation_request! }

  before { sign_in_as(regulator) }

  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at)
  def rows = CSV.parse(response.body.dup.force_encoding("UTF-8").delete_prefix("﻿"), col_sep: ";", headers: true)

  it "200 text/csv como anexo, sem cache, nome com a data e sem dado pessoal; uma trilha de lista com os ids" do
    expect { get "/regulation/exports/state.csv" }.to change { viewed.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.headers["Content-Type"]).to include("charset=utf-8")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    disposition = response.headers["Content-Disposition"]
    expect(disposition).to start_with("attachment")
    expect(disposition).to include("regulacao-estado-2026-10-28.csv")
    expect(disposition).not_to include(external.patient.display_name.parameterize)
    expect(disposition).not_to include(external.id)
    expect(response.body.dup.force_encoding("UTF-8")).to start_with("﻿pedido_id;")
    expect(rows.map { |r| r["pedido_id"] }).to eq([ external.id ])
    expect(viewed.last.payload).to eq("access" => "regulation", "regulation_request_ids" => [ external.id ], "user_id" => regulator.id)
  end

  it "status=pending traz os pendentes; sem pedido na situação → só o cabeçalho e nenhuma trilha" do
    get "/regulation/exports/state.csv", params: { status: "pending" }
    expect(rows.map { |r| r["pedido_id"] }).to eq([ waiting.id ])
    expect { get "/regulation/exports/state.csv", params: { status: "completed" } }.not_to change { viewed.count }
    expect(response).to have_http_status(:ok)
    expect(rows.size).to eq(0)
  end

  it "status=draft, missed, lixo ou lista → 422 invalid_request com path status; sem trilha" do
    [ "draft", "missed", "xyz", [ "external" ] ].each do |status|
      expect { get "/regulation/exports/state.csv", params: { status: status } }.not_to change { viewed.count }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "status" } ])
    end
  end

  it "outra chave de query → 422 invalid_request com o path da chave" do
    get "/regulation/exports/state.csv", params: { cpf: "123" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cpf" } ])
    get "/regulation/exports/state.csv", params: { status: "external", patient: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "patient" } ])
  end

  it "profissional e administrador → 403; sem sessão → 401; interruptor desligado → 403 feature_disabled" do
    [ doctor!(create_unit("UBS Export")), regulation_admin! ].each do |user|
      sign_in_as(user)
      get "/regulation/exports/state.csv"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
    sign_in_as(regulator)
    Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
    get "/regulation/exports/state.csv"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    Session.delete_all
    get "/regulation/exports/state.csv"
    expect(response).to have_http_status(:unauthorized)
  end
end
