require "rails_helper"

# ADR 0035, Invariantes. Prova por comportamento (rotas reais) e, para a
# comparação em tempo constante e a chave, também pelo código.
RSpec.describe "Invariantes da linha do tempo (ADR 0035)", type: :request do
  let(:unit) { create_unit("UBS Centro").tap { |u| u.update!(cnes: "1234567") } }
  let(:doctor) { doctor!(unit).tap { |u| u.professional.update!(cpf: "52998224725") } }
  let(:citizen) { verified_citizen!(161) }
  def body = JSON.parse(response.body)

  def viewed_accesses = DomainEvent.where(name: "clinical_record.viewed").map { |e| e.payload["access"] }

  context "modo record com documentos" do
    before { timeline_city!(documents: true); ciap2_release!; cid10_release!; sigtap_release! }

    it "toda leitura gera trilha: timeline e citizen" do
      attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
      sign_in_as(doctor)
      get "/attendance/timeline", params: { attendance_id: attendance.id }
      sign_in_citizen(citizen.phone)
      get "/citizen/history", params: { citizen_id: citizen.id }
      get "/citizen/health_summary", params: { citizen_id: citizen.id }
      expect(viewed_accesses).to eq(%w[timeline citizen])
    end

    it "o cidadão nunca vê texto clínico livre, CID sem nome, número SNCR, talão nem dado de outra pessoa" do
      allow(ClinicalTerms).to receive(:label).and_call_original
      allow(ClinicalTerms).to receive(:label).with("cid10", "N390", anything).and_return(nil)
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                             subjective: "MARCADOR-SOAP queixa", plan: "MARCADOR-PLANO",
                                             evaluated_problems: [ { "terminology" => "cid10", "code" => "N390", "action" => "add" } ])
      raw_document!(consultation: consultation, kind: "prescription", issue_mode: "paper",
                    content: { "items" => [ { "printed_description" => "MARCADOR-ITEM" } ],
                               "sncr" => { "number" => "2602.6-53.0000001" } })
      raw_document!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper",
                    content: { "notification_type" => "B", "paper_number" => "TALAO-MARCADOR", "item" => {} })
      other = verified_citizen!(162, social_name: "OUTRA-PESSOA")
      finalized_consultation!(unit: unit, doctor: doctor, citizen: other)
      sign_in_citizen(citizen.phone)
      get "/citizen/history", params: { citizen_id: citizen.id }
      history = response.body
      get "/citizen/health_summary", params: { citizen_id: citizen.id }
      [ history, response.body ].each do |text|
        expect(text).not_to include("MARCADOR-SOAP", "MARCADOR-PLANO", "MARCADOR-ITEM", "N390", "2602.6-53", "TALAO-MARCADOR",
                                    "OUTRA-PESSOA")
      end
    end

    it "par só declarado nunca entra na pessoa nem vê resumo ou documento" do
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
      document = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
      declared = Citizen.create!(cpf: citizen.cpf, phone: "+5541966660001", verification_level: "declared")
      completed_web_triage_for(declared)
      expect(Timeline::Person.for_patient(consultation.patient).citizen_ids).not_to include(declared.id)
      sign_in_citizen(declared.phone)
      get "/citizen/history", params: { citizen_id: declared.id }
      expect(body["entries"].map { |e| e["kind"] }.uniq).to eq(%w[triage])
      get "/citizen/health_summary", params: { citizen_id: declared.id }
      expect(response).to have_http_status(:forbidden)
      get "/citizen/documents/#{document.id}/pdf", params: { citizen_id: declared.id }
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "modo integrado com o PEC" do
    before do
      timeline_city!(record_mode: "integrated", clinical_record: false, pec: true)
      pec_settings!
    end

    it "a página do PEC gera trilha pec_external e só abre com assinatura válida, recente e de uso único" do
      doctor
      path = signed_pec_path(professional: "52998224725", citizen: citizen.cpf, cnes: "1234567")
      get path
      expect(response).to have_http_status(:ok)
      get path
      expect(response).to have_http_status(:forbidden)
      get signed_pec_path(professional: "52998224725", citizen: citizen.cpf, cnes: "1234567", at: 6.minutes.ago)
      expect(response).to have_http_status(:forbidden)
      expect(viewed_accesses).to eq(%w[pec_external])
    end

    it "a chave HMAC nunca é devolvida nem logada; a comparação é em tempo constante" do
      expect(PecSetting.current.inspect).not_to include(TimelineHelpers::PEC_KEY)
      log = capture_log { get signed_pec_path(professional: "52998224725", citizen: citizen.cpf, cnes: "1234567") }
      expect(log).not_to include(TimelineHelpers::PEC_KEY)
      expect(response.body).not_to include(TimelineHelpers::PEC_KEY)
      fields = Maintenance::Schema.types.values.select { |t| t.respond_to?(:fields) }.flat_map { |t| t.fields.keys }
      expect(fields.grep(/hmacKey\z|hmac_key\z/)).to be_empty
      source = Rails.root.join("app/services/pec_external/signature.rb").read
      expect(source).to include("ActiveSupport::SecurityUtils.secure_compare")
      expect(source).not_to match(/expected\s*==|==\s*expected/)
      # Quem LÊ o valor (`.hmac_key`, não `hmac_key_configured?`/`_updated_at`): só a conferência da assinatura.
      readers = Dir[Rails.root.join("app/**/*.rb")].select { |f| File.read(f).match?(/\.hmac_key\b(?!_)/) }
                                                  .map { |f| f.delete_prefix("#{Rails.root}/") }
      expect(readers).to eq(%w[app/services/pec_external/authorize.rb])
    end
  end
end
