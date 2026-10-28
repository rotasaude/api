require "rails_helper"

RSpec.describe Surveillance::CreateNotification do
  include ActiveSupport::Testing::TimeHelpers
  before { surveillance_city! }
  let(:patient) { surveillance_patient!(3) }
  let(:unit) { HealthUnit.create!(name: "UBS Norte #{SecureRandom.hex(2)}", kind: "ubs", cnes: "7654321") }
  let(:dengue) { Surveillance::Diseases.find("dengue", today: Time.zone.today) }
  let(:officer) { surveillance_officer! }

  def create(**over)
    described_class.call(**{ patient: patient, disease: dengue, origin: "manual", unit: unit, by: officer, suspected_at: Time.current }.merge(over))
  end

  it "prazo semanal e imediato a partir da suspeita; CNES congelado; evento só com ids" do
    n = create.payload[:notification]
    expect(n.due_at).to be_within(1.second).of(7.days.from_now)
    expect([ n.status, n.unit_cnes, n.notifier_user_id ]).to eq([ "notified", "7654321", officer.id ])
    event = DomainEvent.where(name: "disease_notification.created").last
    expect(event.payload).to eq("notification_id" => n.id, "immediate" => false)
  end

  it "aberta bloqueia; fechada há menos que a janela bloqueia; depois da janela e dismissed liberam" do
    first = create.payload[:notification]
    expect(create.reason).to eq(:already_notified)
    expect(create.details).to eq(notification_id: first.id)
    first.update!(status: "closed", classification: "confirmed", closed_at: Time.current)
    expect(create.reason).to eq(:already_notified)
    travel_to(31.days.from_now) { expect(create).to be_ok }
  end

  it "possível descartada não bloqueia; rede de segurança nasce possible sem notificador" do
    possible = create(origin: "safety_net", by: nil).payload[:notification]
    expect([ possible.status, possible.notifier_user_id ]).to eq([ "possible", nil ])
    possible.update!(status: "dismissed", dismissed_at: Time.current)
    expect(create).to be_ok
  end

  it "raça/cor 03 do paciente nasce 4 na ficha; sintomas depois da suspeita recusados" do
    patient.update!(race_color: "03", address_street: "Rua das Acácias", address_zip: "81020000")
    n = create.payload[:notification]
    expect(n.form).to include("race_color" => "4", "residence_street" => "Rua das Acácias", "residence_zip" => "81020000")
    expect(create(symptoms_on: Date.tomorrow, disease: Surveillance::Diseases.find("tuberculose", today: Date.current)).reason)
      .to eq(:invalid_symptoms_on)
  end

  it "doença imediata: prazo de 24 h; congela prazo, versão da lista, bairro e grava o evento do andamento" do
    sarampo = Surveillance::Diseases.find("sarampo", today: Time.zone.today)
    centro = Neighborhood.create!(name: "Centro #{SecureRandom.hex(2)}", source: "manual")
    Citizen.where(patient_id: patient.id).update_all(neighborhood_id: centro.id)
    n = create(disease: sarampo, symptoms_on: Time.zone.today - 2).payload[:notification]
    expect(n.due_at).to be_within(1.second).of(24.hours.from_now)
    expect([ n.deadline, n.disease_list_version, n.neighborhood_id, n.symptoms_on, n.origin ])
      .to eq([ "immediate", sarampo.list_version, centro.id, Time.zone.today - 2, "manual" ])
    expect(n.events.map { |e| [ e.status, e.by_user_id ] }).to eq([ [ "notified", officer.id ] ])
    expect(DomainEvent.where(name: "disease_notification.created").last.payload["immediate"]).to be(true)
  end

  it "o dia da suspeita é o do fuso da cidade (01h UTC = 22h da véspera em São Paulo)" do
    at = Time.current.utc.beginning_of_day + 1.hour
    n = create(suspected_at: at).payload[:notification]
    expect([ n.suspected_on, n.due_at ]).to eq([ at.to_date - 1, at + 7.days ])
    expect(create(origin: "safety_net", disease: Surveillance::Diseases.find("tuberculose"), suspected_at: at,
                  symptoms_on: at.to_date).reason).to eq(:invalid_symptoms_on)
  end

  it "rede de segurança nunca grava notificador, mesmo com by" do
    n = create(origin: "safety_net").payload[:notification]
    expect([ n.notifier_user_id, n.events.first.by_user_id, n.events.first.status ]).to eq([ nil, nil, "possible" ])
  end

  it "residência fora: só com IBGE de 7 dígitos, e IBGE só com residência fora — recusa antes de gravar" do
    expect { expect(create(resident_elsewhere: true).reason).to eq(:invalid_residence) }.not_to change(DiseaseNotification, :count)
    expect(create(resident_elsewhere: true, residence_ibge: "41069").reason).to eq(:invalid_residence)
    expect(create(resident_elsewhere: false, residence_ibge: "4106902").reason).to eq(:invalid_residence)
    expect(create(resident_elsewhere: "yes", residence_ibge: "4106902").reason).to eq(:invalid_residence)
    n = create(resident_elsewhere: true, residence_ibge: "4106902").payload[:notification]
    expect([ n.resident_elsewhere, n.residence_ibge ]).to eq([ true, "4106902" ])
  end

  it "corrida perdida para o índice único: already_notified num savepoint, e a transação de fora segue utilizável" do
    first = create.payload[:notification]
    allow(Surveillance::Duplicates).to receive(:blocking).and_return(nil)
    ApplicationRecord.transaction do
      result = create
      expect([ result.reason, result.details ]).to eq([ :already_notified, { notification_id: first.id } ])
      expect(DiseaseNotification.count).to eq(1)
    end
    expect(DomainEvent.where(name: "disease_notification.created").count).to eq(1)
  end

  it "recusa nunca carrega dado do paciente, da doença nem a mensagem do Postgres" do
    first = create(symptoms_on: Time.zone.today).payload[:notification]
    result = create
    expect(result.message).to be_nil
    expect(result.details.keys).to eq([ :notification_id ])
    expect(result.details[:notification_id]).to eq(first.id)
  end

  it "Desvio 6: consulta e manual sem quem grava, ou rede de segurança fora de possible → ArgumentError, sem gravar" do
    expect { create(by: nil) }.to raise_error(ArgumentError)
    expect { create(origin: "consultation", by: nil) }.to raise_error(ArgumentError)
    expect { create(origin: "safety_net", status: "notified") }.to raise_error(ArgumentError)
    expect(DiseaseNotification.count).to eq(0)
    expect(create(origin: "safety_net", status: "possible", by: nil)).to be_ok
  end

  it "suspeita como Date: 00:00 no fuso da cidade, due_at continua instante" do
    n = create(suspected_at: Time.zone.today).payload[:notification]
    expect([ n.suspected_on, n.due_at ]).to eq([ Time.zone.today, Time.zone.today.in_time_zone + 7.days ])
  end

  it "residente fora: a ficha não leva a UF da cidade" do
    city_profile!.update!(uf: "PR")
    patient.update!(address_street: "Rua das Acácias")
    away = create(resident_elsewhere: true, residence_ibge: "3550308").payload[:notification]
    expect(away.form).not_to have_key("residence_uf")
    expect(create(disease: Surveillance::Diseases.find("tuberculose")).payload[:notification].form["residence_uf"]).to eq("PR")
  end

  it "helper notification!: safety_net sem status nasce possible" do
    expect(notification!(patient: patient, origin: "safety_net").status).to eq("possible")
  end
end
