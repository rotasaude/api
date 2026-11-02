require "rails_helper"

# Módulo 29, Task 18 (ADR 0047; §15 V13): critérios de campanha sobre a situação
# vacinal materializada e o vaccinated_count. Review Focus 2, lado campanha:
# caderneta não conferida nunca convoca como atraso.
RSpec.describe "Critérios de vacinação das campanhas" do
  let!(:city) { vaccination_city! }
  let(:today) { Time.zone.today }
  let(:penta) { { "kind" => "vaccine_overdue", "immunobiological_codes" => [ "42" ] } }
  let(:unchecked) { { "kind" => "vaccination_record_unchecked" } }

  def ids(klass, params) = Citizen.where(id: klass.relation(params)).pluck(:id)

  # Cidadão com paciente de nascimento dado; estado vacinal recalculado.
  def child!(months_ago:, checked: false)
    patient = vaccine_patient!(birth_date: today << months_ago)
    citizen = person!
    citizen.update!(verification_level: "verified", patient: patient)
    check!(patient) if checked
    Vaccination::Statuses.refresh!(patient)
    [ citizen, patient ]
  end

  # O público congela depois do envio: nasce rascunho com o público e vira sent.
  def sent_campaign_for!(audience)
    campaign = draft_campaign!(audience: audience)
    campaign.update_columns(status: "sending", dispatched_by_user_id: campaign.created_by_user_id)
    campaign.update_columns(status: "sent", sms_enabled: false, recipients_count: 0, phones_count: 0, dispatched_at: Time.current)
    campaign.reload
  end

  def check!(patient)
    room = vaccine_room!
    VaccinationRecordCheck.create!(patient: patient, mode: "confirmed_complete", checked_at: Time.current,
                                   checked_by_user_id: room_member!(room).id, vaccine_room_id: room.id)
  end

  it "todo kind do schema tem classe (e vice-versa) e os dois novos estão registrados" do
    expect(Campaigns::AudienceSchema::CRITERIA.keys).to match_array(Campaigns::Criteria::KINDS.keys)
    expect(Campaigns::Criteria::KINDS.keys).to include("vaccine_overdue", "vaccination_record_unchecked")
  end

  describe "Review Focus 2: criança de 1 ano, caderneta não conferida, sem dose" do
    it "vaccine_overdue NÃO convoca; vaccination_record_unchecked convoca" do
      citizen, = child!(months_ago: 12)
      expect(ids(Campaigns::Criteria::VaccineOverdue, penta)).not_to include(citizen.id)
      expect(ids(Campaigns::Criteria::VaccinationRecordUnchecked, unchecked)).to include(citizen.id)
    end

    it "depois da conferência confirmed_complete + refresh!, vaccine_overdue convoca pela penta e unchecked deixa de convocar" do
      citizen, patient = child!(months_ago: 12)
      check!(patient)
      Vaccination::Statuses.refresh!(patient)
      expect(ids(Campaigns::Criteria::VaccineOverdue, penta)).to include(citizen.id)
      expect(ids(Campaigns::Criteria::VaccinationRecordUnchecked, unchecked)).not_to include(citizen.id)
    end
  end

  describe "vaccine_overdue" do
    it "respeita a faixa de idade em meses (inclusiva) e os códigos" do
      citizen, = child!(months_ago: 12, checked: true)
      expect(ids(Campaigns::Criteria::VaccineOverdue, penta.merge("age_min_months" => 12, "age_max_months" => 12))).to include(citizen.id)
      expect(ids(Campaigns::Criteria::VaccineOverdue, penta.merge("age_min_months" => 24))).not_to include(citizen.id)
      expect(ids(Campaigns::Criteria::VaccineOverdue, penta.merge("age_max_months" => 11))).not_to include(citizen.id)
      expect(ids(Campaigns::Criteria::VaccineOverdue, penta.merge("immunobiological_codes" => [ "999" ]))).not_to include(citizen.id)
    end

    it "cidadão sem paciente vinculado não entra em nenhum dos dois" do
      loose = person!
      expect(ids(Campaigns::Criteria::VaccineOverdue, penta)).not_to include(loose.id)
      expect(ids(Campaigns::Criteria::VaccinationRecordUnchecked, unchecked)).not_to include(loose.id)
    end
  end

  describe "vaccination_record_unchecked" do
    it "respeita a faixa de idade" do
      citizen, = child!(months_ago: 12)
      expect(ids(Campaigns::Criteria::VaccinationRecordUnchecked, unchecked.merge("age_min_months" => 24))).not_to include(citizen.id)
      expect(ids(Campaigns::Criteria::VaccinationRecordUnchecked, unchecked.merge("age_min_months" => 6, "age_max_months" => 12))).to include(citizen.id)
    end
  end

  describe "esquema" do
    def audience(*criteria) = city_audience(*criteria)
    def errors(*criteria) = Campaigns::AudienceSchema.errors(audience(*criteria))

    it "aceita as formas válidas" do
      expect(errors(penta.merge("age_min_months" => 0, "age_max_months" => 1200), unchecked.merge("age_min_months" => 6))).to be_empty
    end

    it "recusa código fora do catálogo com invalid_value no ponteiro do item" do
      expect(errors(penta.merge("immunobiological_codes" => [ "999" ]))).to eq(
        [ { path: "/clinical/all/0/immunobiological_codes/0", message: "invalid_value" } ]
      )
    end

    it "normaliza o zero à esquerda (hepatite B 9/09) e recusa repetição depois de normalizar" do
      expect(errors(penta.merge("immunobiological_codes" => [ "09" ]))).to be_empty
      expect(errors(penta.merge("immunobiological_codes" => %w[9 09]))).to eq([ { path: "/clinical/all/0/immunobiological_codes", message: "duplicate" } ])
    end

    it "recusa lista vazia, mais de 20 códigos e ausência do campo obrigatório" do
      expect(errors(penta.merge("immunobiological_codes" => []))).to eq([ { path: "/clinical/all/0/immunobiological_codes", message: "empty" } ])
      codes = Vaccination::Immunobiologicals.all.map(&:code).first(21)
      expect(codes.size).to be > 20
      expect(errors(penta.merge("immunobiological_codes" => codes))).to eq([ { path: "/clinical/all/0/immunobiological_codes", message: "too_many" } ])
      expect(errors({ "kind" => "vaccine_overdue" })).to eq([ { path: "/clinical/all/0/immunobiological_codes", message: "required" } ])
    end

    it "recusa idade não inteira, fora de 0..1200 e faixa invertida" do
      expect(errors(unchecked.merge("age_min_months" => -1))).to eq([ { path: "/clinical/all/0/age_min_months", message: "invalid_value" } ])
      expect(errors(unchecked.merge("age_max_months" => 1201))).to eq([ { path: "/clinical/all/0/age_max_months", message: "invalid_value" } ])
      expect(errors(unchecked.merge("age_max_months" => "12"))).to eq([ { path: "/clinical/all/0/age_max_months", message: "invalid_value" } ])
      expect(errors(unchecked.merge("age_min_months" => 24, "age_max_months" => 12))).to eq(
        [ { path: "/clinical/all/0/age_min_months", message: "inverted_range" } ]
      )
    end
  end

  describe "interruptor vaccination" do
    it "desligado, a validação do público recusa os dois critérios" do
      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      errors = Campaigns::AudienceValidation.errors(city_audience(penta, unchecked))
      expect(errors).to contain_exactly({ path: "/clinical/all/0/kind", message: "feature_disabled" },
                                        { path: "/clinical/all/1/kind", message: "feature_disabled" })
    end

    it "ligado, a validação aceita" do
      expect(Campaigns::AudienceValidation.errors(city_audience(penta, unchecked))).to be_empty
    end
  end

  describe "vaccinated_count" do
    it "conta quem tomou dose ativa do imunobiológico depois do envio: 0, depois 1; cancelada não conta; anterior ao envio não conta" do
      citizen, patient = child!(months_ago: 12, checked: true)
      campaign = sent_campaign_for!(city_audience(penta))
      recipient = recipient!(campaign, citizen)
      room = vaccine_room!

      expect(Campaigns::Presenter.full(campaign)[:vaccinated_count]).to eq(0)

      create_immunization!(room, patient: patient, applied_at: recipient.created_at - 1.hour)
      expect(Campaigns::Presenter.full(campaign)[:vaccinated_count]).to eq(0)

      other_code = create_immunization!(room, patient: patient, immunobiological_code: "9", stock_lot: vaccine_lot!(room, code: "9"),
                                                applied_at: recipient.created_at + 1.hour)
      expect(Campaigns::Presenter.full(campaign)[:vaccinated_count]).to eq(0)
      expect(other_code).to be_persisted

      dose = create_immunization!(room, patient: patient, applied_at: recipient.created_at + 2.hours)
      expect(Campaigns::Presenter.full(campaign)[:vaccinated_count]).to eq(1)

      dose.update_columns(cancelled_at: Time.current, cancelled_by_user_id: dose.vaccinator_user_id, cancel_reason: "dose registrada por engano")
      expect(Campaigns::Presenter.full(campaign)[:vaccinated_count]).to eq(0)
    end

    it "é nulo sem critério vaccine_overdue ou com a campanha fora de sent" do
      with_unchecked = sent_campaign_for!(city_audience(unchecked))
      expect(Campaigns::Presenter.full(with_unchecked.reload)[:vaccinated_count]).to be_nil

      draft = draft_campaign!(audience: city_audience(penta))
      expect(Campaigns::Presenter.full(draft)[:vaccinated_count]).to be_nil

      expect(Campaigns::Presenter.full(sent_campaign_for!(city_audience(penta)))[:vaccinated_count]).to eq(0)
    end
  end
end
