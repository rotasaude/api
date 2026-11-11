require "rails_helper"

# Módulo 32b (contrato §12 Q8; §4): enquanto o encontro da urgência estiver
# aberto, qualquer médico (225*) com vínculo ativo na UPA do atendimento lê o
# prontuário em contexto (trilha clinical_record.viewed a cada leitura) e
# escreve adendos na consulta `urgency` finalizada (o autor do adendo é quem
# escreve; consultation.addendum_added). Fechado o encontro, ou fora da UPA,
# ou com outro CBO, ou noutra consulta, volta a regra do 19a.
RSpec.describe "Evolução do encontro aberto por outro médico da UPA", type: :request do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:next_shift) { upa_doctor!(upa) }
  let(:encounter) { arrived!(upa).tap { |e| classified!(e, color: "orange", by: nurse, pain_scale: 8) } }
  let!(:consultation) do
    ciap2_release!; cid10_release!; sigtap_release!
    called!(encounter, by: doctor)
    finalized_urgency!(encounter, doctor: doctor)
  end

  def addendum!(text: "Evolução: estável, mantida observação")
    json_post "/attendance/consultations/#{consultation.id}/addenda", reason: "evolução do plantão", text: text
  end

  def views_by(user) = DomainEvent.where(name: "clinical_record.viewed").select { |e| e.payload["user_id"] == user.id }

  def close!
    result = Urgency::RecordOutcome.call(encounter: encounter.reload, attrs: { "kind" => "discharged" }, by: doctor)
    raise "desfecho recusado: #{result.reason}" if result.failure?
  end

  describe "adendo" do
    it "o médico do plantão seguinte escreve com o encontro aberto: 201, autor ele, evento com ids" do
      sign_in_as(next_shift)
      addendum!
      expect(response).to have_http_status(:created)
      addendum = ConsultationAddendum.find(json_body["id"])
      expect(addendum.author_user_id).to eq(next_shift.id)
      expect(addendum.consultation_id).to eq(consultation.id)
      event = DomainEvent.where(name: "consultation.addendum_added").sole
      expect(event.payload).to eq("consultation_id" => consultation.id, "addendum_id" => addendum.id)
    end

    it "fechado o encontro: o outro médico recebe o 403 not_author do 19a; a autora segue escrevendo" do
      close!
      sign_in_as(next_shift)
      addendum!
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "not_author")
      expect(ConsultationAddendum.count).to eq(0)

      sign_in_as(doctor)
      addendum!
      expect(response).to have_http_status(:created)
      expect(ConsultationAddendum.sole.author_user_id).to eq(doctor.id)
    end

    it "a autora escreve com o encontro aberto, como no 19a" do
      sign_in_as(doctor)
      addendum!
      expect(response).to have_http_status(:created)
      expect(ConsultationAddendum.sole.author_user_id).to eq(doctor.id)
    end

    it "médico de outra UPA e enfermeiro(a) 2235 da mesma UPA → 403 not_author" do
      [ upa_doctor!(upa!), nurse ].each do |user|
        sign_in_as(user)
        addendum!
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "not_author")
      end
      expect(ConsultationAddendum.count).to eq(0)
    end

    it "consulta que não é urgency, de outra autora: 403 not_author (19a intocado)" do
      ubs = create_unit("UBS Evolução")
      general = finalized_consultation!(unit: ubs, doctor: doctor!(ubs), citizen: verified_citizen!(1))
      sign_in_as(doctor!(ubs))
      json_post "/attendance/consultations/#{general.id}/addenda", reason: "evolução do plantão", text: "texto"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "not_author")
    end
  end

  describe "prontuário" do
    it "o médico do plantão seguinte lê em contexto com o encontro aberto, uma trilha por leitura" do
      sign_in_as(next_shift)
      get "/attendance/attendances/#{encounter.attendance_id}/record"
      expect(response).to have_http_status(:ok)
      expect(json_body["access"]).to eq("in_context")
      expect(views_by(next_shift).map(&:payload)).to contain_exactly(
        include("patient_id" => encounter.patient.id, "access" => "in_context")
      )

      get "/attendance/consultations/#{consultation.id}"
      expect(response).to have_http_status(:ok)
      expect(views_by(next_shift).size).to eq(2)
    end

    it "fechado o encontro: fora de contexto (403 out_of_context); só a abertura justificada lê" do
      close!
      sign_in_as(next_shift)
      get "/attendance/attendances/#{encounter.attendance_id}/record"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "out_of_context")
      get "/clinical_record/patients/#{encounter.patient.id}"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "opening_required")
      expect(views_by(next_shift)).to be_empty

      now = Time.current
      ClinicalRecordOpening.create!(patient: encounter.patient, user: next_shift, reason_code: "case_review",
                                    created_at: now, expires_at: now + 30.minutes)
      get "/clinical_record/patients/#{encounter.patient.id}"
      expect(response).to have_http_status(:ok)
      expect(views_by(next_shift).sole.payload).to include("access" => "justified")
    end

    it "médico de outra UPA e enfermeiro(a) 2235 com o encontro aberto: 403 out_of_context, sem trilha" do
      [ upa_doctor!(upa!), nurse ].each do |user|
        sign_in_as(user)
        get "/attendance/attendances/#{encounter.attendance_id}/record"
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "out_of_context")
        expect(views_by(user)).to be_empty
      end
    end
  end

  describe "fim da janela" do
    def refused_both!
      sign_in_as(next_shift)
      get "/attendance/attendances/#{encounter.attendance_id}/record"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "out_of_context")
      addendum!
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "not_author")
      expect(views_by(next_shift)).to be_empty
      expect(ConsultationAddendum.count).to eq(0)
    end

    it "atendimento fechado pelo 13 com urgency_care desligado (o encontro segue in_care): 403 nos dois" do
      result = Attendances::Close.call(attendance: encounter.attendance.reload, outcome: "discharged", referral_unit_id: nil,
                                       referral_note: nil, by: doctor, urgency: false)
      expect(result).to be_ok
      expect(encounter.reload.state).to eq("in_care")
      expect(encounter.attendance.reload.status).to eq("closed")
      refused_both!
    end

    it "vínculo do médico na UPA encerrado com o encontro aberto: 403 nos dois, nunca 404" do
      next_shift.professional.links.active.sole.update!(ended_at: Time.current, ended_by_user: urgency_admin!)
      expect(encounter.reload).not_to be_closed
      refused_both!
    end
  end
end
