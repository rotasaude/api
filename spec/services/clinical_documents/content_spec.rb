# spec/services/clinical_documents/content_spec.rb
require "rails_helper"

# Spec §4; contrato §2/§3: o conteúdo de cada tipo, validado campo a campo.
RSpec.describe "Conteúdo dos documentos" do
  include ActiveSupport::Testing::TimeHelpers

  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:today) { Date.new(2026, 10, 9) }

  describe ClinicalDocuments::Content::SickNote do
    def call(input) = described_class.call(input, today: today)

    it "afastamento: dias, início (padrão hoje) e CID só com autorização" do
      expect(call("type" => "leave", "days" => 3).payload[:content])
        .to eq("type" => "leave", "days" => 3, "start_on" => "2026-10-09", "cid_authorized" => false, "note" => nil)
      content = call("type" => "leave", "days" => 2, "start_on" => "2026-10-08", "cid10" => { "code" => "I10" },
                     "cid_authorized" => true, "note" => "Repouso relativo").payload[:content]
      expect(content).to include("cid10" => { "code" => "I10", "label" => "Hipertensão essencial (primária)" },
                                 "cid_authorized" => true, "note" => "Repouso relativo")
      expect(call("type" => "leave", "days" => 2, "cid10" => { "code" => "I10" }).reason).to eq(:cid_requires_authorization)
      expect(call("type" => "leave", "days" => 2, "cid10" => { "code" => "Z999" }, "cid_authorized" => true).details).to eq(field: "cid10")
    end

    it "afastamento recusa dias e início fora da faixa e campos do acompanhante" do
      expect(call("type" => "leave", "days" => 0).details).to eq(field: "days")
      expect(call("type" => "leave", "days" => "3").details).to eq(field: "days")
      expect(call("type" => "leave", "days" => 3, "start_on" => "2026-08-01").details).to eq(field: "start_on")
      expect(call("type" => "leave", "days" => 3, "start_on" => "2026-10-10").details).to eq(field: "start_on")
      expect(call("type" => "leave", "days" => 3, "companion_name" => "Ana").details).to eq(field: "companion_name")
      expect(call("type" => "outro").details).to eq(field: "type")
    end

    it "acompanhante: nome, parentesco, motivo CLT; nunca CID nem dias" do
      ok = call("type" => "companion", "companion_name" => "Ana Paula Souza", "companion_kinship" => "mãe",
                "companion_reason" => "clt_473_xi")
      expect(ok.payload[:content]).to eq("type" => "companion", "companion_name" => "Ana Paula Souza",
                                         "companion_kinship" => "mãe", "companion_reason" => "clt_473_xi", "cid_authorized" => false, "note" => nil)
      expect(call("type" => "companion", "companion_name" => "Ana Paula", "companion_kinship" => "mãe",
                  "companion_reason" => "clt_473_xi", "cid10" => { "code" => "I10" }, "cid_authorized" => true).reason)
        .to eq(:companion_cid_not_allowed)
      expect(call("type" => "companion", "companion_name" => "Ana Paula", "companion_kinship" => "mãe",
                  "companion_reason" => "clt_473_xi", "days" => 1).details).to eq(field: "days")
      expect(call("type" => "companion", "companion_name" => "An", "companion_kinship" => "mãe",
                  "companion_reason" => "clt_473_xi").details).to eq(field: "companion_name")
      with_start = call("type" => "companion", "start_on" => "2026-10-08", "companion_name" => "Ana Paula Souza",
                       "companion_kinship" => "mãe", "companion_reason" => "clt_473_xi").payload[:content]
      expect(with_start).to include("start_on" => "2026-10-08")
      expect(with_start).not_to have_key("days")
      %w[2026-08-01 2026-10-10].each do |date|
        expect(call("type" => "companion", "start_on" => date, "companion_name" => "Ana Paula Souza",
                    "companion_kinship" => "mãe", "companion_reason" => "clt_473_xi").details).to eq(field: "start_on")
      end
      expect(call("type" => "companion", "companion_name" => "Ana Paula", "companion_kinship" => "mãe",
                  "companion_reason" => "art_999").details).to eq(field: "companion_reason")
    end
  end

  describe ClinicalDocuments::Content::Declaration do
    let(:unit) { create_unit }
    let(:attendance) { walk_in_attendance!(unit, citizen: verified_citizen!(1), checked_in_at: Time.zone.parse("2026-10-09 08:12")) }

    it "horário de chegada do check-in por padrão; período no lugar do horário; unidade do atendimento" do
      content = described_class.call({}, attendance: attendance).payload[:content]
      expect(content).to eq("date" => "2026-10-09", "arrived_at" => "08:12", "unit_name" => unit.name)
      content = described_class.call({ "period" => "morning", "companion_name" => "Carlos Lima",
                                       "issuer_registration" => "12345" }, attendance: attendance).payload[:content]
      expect(content).to eq("date" => "2026-10-09", "period" => "morning", "unit_name" => unit.name,
                            "companion_name" => "Carlos Lima", "issuer_registration" => "12345")
    end

    it "recusa período com horário, horário inválido e saída antes da chegada" do
      expect(described_class.call({ "period" => "morning", "arrived_at" => "08:00" }, attendance: attendance).details).to eq(field: "period")
      expect(described_class.call({ "arrived_at" => "25:00" }, attendance: attendance).details).to eq(field: "arrived_at")
      expect(described_class.call({ "arrived_at" => "10:00", "left_at" => "09:00" }, attendance: attendance).details).to eq(field: "left_at")
      expect(described_class.call({ "period" => "night" }, attendance: attendance).details).to eq(field: "period")
    end

    # Revisão final I1: a consulta finalizada no dia seguinte não vira hora de
    # saída (nem recusa um left_at que ninguém digitou, nem atesta outro dia).
    context "encerramento do atendimento" do
      let(:doctor) { doctor!(unit) }

      def closed_attendance(checked_in:, closed:)
        consultation = travel_to(Time.zone.parse(checked_in)) do
          started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
        end
        travel_to(Time.zone.parse(closed)) do
          Consultations::SaveDraft.call(consultation: consultation, params: draft_body, by: doctor)
          result = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
          raise "finalização recusada: #{result.reason}" if result.failure?
        end
        consultation.attendance.reload
      end

      it "no mesmo dia do check-in: a saída padrão é o encerramento" do
        visit = closed_attendance(checked_in: "2026-10-09 08:12", closed: "2026-10-09 11:40")
        expect(described_class.call({}, attendance: visit).payload[:content])
          .to eq("date" => "2026-10-09", "arrived_at" => "08:12", "left_at" => "11:40", "unit_name" => unit.name)
      end

      it "encerrado em D+1, check-in à tarde: não recusa; a saída fica ausente" do
        visit = closed_attendance(checked_in: "2026-10-09 14:00", closed: "2026-10-10 09:00")
        result = described_class.call({}, attendance: visit)
        expect(result).to be_ok
        expect(result.payload[:content]).to eq("date" => "2026-10-09", "arrived_at" => "14:00", "unit_name" => unit.name)
      end

      it "encerrado em D+1, check-in de manhã: não atesta a hora de outro dia" do
        visit = closed_attendance(checked_in: "2026-10-09 08:00", closed: "2026-10-10 17:30")
        expect(described_class.call({}, attendance: visit).payload[:content]).not_to have_key("left_at")
      end
    end
  end

  describe ClinicalDocuments::Content::ExamRequisition do
    let(:unit) { create_unit }
    let(:doctor) { doctor!(unit) }

    it "renderiza os exames vigentes da consulta, com a competência; sem exame → no_exam_requests" do
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
      content = described_class.call({ "note" => "Jejum de 8 horas" }, consultation: consultation).payload[:content]
      expect(content["exams"]).to eq([ { "sigtap_code" => "0202010503", "label" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA",
                                         "competence" => Time.zone.today.strftime("%Y%m") } ])
      expect(content["note"]).to eq("Jejum de 8 horas")
      empty = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2), exam_requests: [])
      expect(described_class.call({}, consultation: empty).reason).to eq(:no_exam_requests)
    end

    # Revisão final M2: sem rótulo SIGTAP o canônico seria inválido; recusa na emissão.
    it "exame sem rótulo SIGTAP na competência → invalid_content field exams" do
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
      allow(ClinicalTerms::SigtapExams).to receive(:label).and_return(nil)
      result = described_class.call({}, consultation: consultation)
      expect([ result.reason, result.details ]).to eq([ :invalid_content, { field: "exams" } ])
    end
  end
end
