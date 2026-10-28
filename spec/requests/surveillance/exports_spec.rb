require "rails_helper"
require "csv"

# Módulo 25, Task 15 (contrato §7, K10): a ficha em PDF e o CSV da semana —
# só `surveillance`, sem cache, sem dado pessoal no nome do arquivo, com trilha.
RSpec.describe "Vigilância — saídas", type: :request do
  let!(:city) { surveillance_city! }
  let(:officer) { surveillance_officer! }
  let(:unit) { create_unit("UBS Vigia").tap { |u| u.update!(cnes: "2345678") } }
  let(:patient) { surveillance_patient!(1) }
  let(:week) { Surveillance::EpiWeek.new(year: 2026, week: 42) }
  let!(:notification) { notification!(patient: patient, unit: unit, suspected_at: Time.zone.local(2026, 10, 20, 12)) }

  before { sign_in_as(officer) }

  def trail_events = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at)

  describe "GET /surveillance/notifications/:id/form.pdf" do
    it "devolve o PDF como anexo sem dado pessoal no nome, sem cache, e grava uma trilha por pessoa" do
      expect { get "/surveillance/notifications/#{notification.id}/form.pdf" }.to change { trail_events.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Content-Disposition"]).to start_with(%(attachment; filename="notificacao-#{notification.id}.pdf"))
      expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include("Notificação Individual")
      payload = trail_events.last.payload
      expect(payload).to include("access" => "surveillance", "user_id" => officer.id, "person_ref" => "patient:#{patient.id}")
      expect(payload.to_s).not_to include(patient.full_name)
    end

    it "id desconhecido ou malformado → 404, sem trilha" do
      expect { get "/surveillance/notifications/#{SecureRandom.uuid}/form.pdf" }.not_to change { trail_events.count }
      expect([ response.status, JSON.parse(response.body) ]).to eq([ 404, { "error" => "not_found" } ])
      get "/surveillance/notifications/abc/form.pdf"
      expect(response).to have_http_status(:not_found)
    end

    it "query não é aceita → 422 invalid_request" do
      get "/surveillance/notifications/#{notification.id}/form.pdf", params: { cpf: patient.cpf }
      expect([ response.status, JSON.parse(response.body) ]).to eq([ 422, { "error" => "invalid_request" } ])
    end

    it "analyst e health_professional → 403" do
      [ staff_with("analista-#{SecureRandom.hex(2)}@cidade.gov.br", "analyst"), doctor!(unit) ].each do |user|
        sign_in_as(user)
        get "/surveillance/notifications/#{notification.id}/form.pdf"
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET /surveillance/exports/week.csv" do
    it "devolve o CSV da semana como anexo, sem cache, e grava a trilha de lista com os ids" do
      expect { get "/surveillance/exports/week.csv", params: { week: "2026-42" } }.to change { trail_events.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["Content-Disposition"]).to start_with(%(attachment; filename="notificacoes-2026-42.csv"))
      body = response.body.dup.force_encoding("UTF-8")
      expect(CSV.parse(body.delete_prefix("﻿"), col_sep: ";", headers: true).map { |r| r["notificacao_id"] }).to eq([ notification.id ])
      expect(trail_events.last.payload).to include("access" => "surveillance", "notification_ids" => [ notification.id ], "user_id" => officer.id)
    end

    it "semana sem notificação → só o cabeçalho e nenhuma trilha" do
      expect { get "/surveillance/exports/week.csv", params: { week: "2026-30" } }.not_to change { trail_events.count }

      expect(response).to have_http_status(:ok)
      expect(response.body.dup.force_encoding("UTF-8").delete_prefix("﻿").lines.size).to eq(1)
    end

    it "semana ausente, inexistente (2026-53), malformada ou em lista → 422 invalid_week" do
      [ {}, { week: "2026-53" }, { week: "2026-4" }, { week: "" }, { week: [ "2026-42" ] } ].each do |params|
        get "/surveillance/exports/week.csv", params: params
        expect([ response.status, JSON.parse(response.body) ]).to eq([ 422, { "error" => "invalid_week" } ])
      end
    end

    it "outra chave de query → 422 invalid_request" do
      get "/surveillance/exports/week.csv", params: { week: "2026-42", patient: "x" }
      expect([ response.status, JSON.parse(response.body) ]).to eq([ 422, { "error" => "invalid_request" } ])
    end

    it "analyst → 403" do
      sign_in_as(staff_with("analista-#{SecureRandom.hex(2)}@cidade.gov.br", "analyst"))
      get "/surveillance/exports/week.csv", params: { week: "2026-42" }
      expect(response).to have_http_status(:forbidden)
    end

    it "sem sessão → 401" do
      Session.delete_all
      get "/surveillance/exports/week.csv", params: { week: "2026-42" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
