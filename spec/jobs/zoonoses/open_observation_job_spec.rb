require "rails_helper"

# Módulo 35b, Task 12 (ADR 0054; contrato §5, Q7, Q16; Review Focus 3): o
# consumidor de disease_notification.{created,updated,transitioned} abre a
# observação do animal agressor. Só com o zoonoses utilizável, a doença
# acidente_animal_raiva, a notificação notified ou investigating e o bloco do
# animal com cão ou gato observável ("true") e exposure_on. Uma observação por
# notificação (o único da tabela); ends_on = exposure_on + observation_days;
# place home (Q16). A ficha editada depois não mexe na observação aberta.
RSpec.describe Zoonoses::OpenObservationJob, type: :job do
  let!(:city) do
    city = zoonoses_city!
    Surveillance::DiseaseList::Load.call unless Surveillance::Diseases.find(Zoonoses::Catalog::OBSERVATION_DISEASE)
    city
  end
  let(:officer) { surveillance_officer! }
  let(:today) { Time.zone.today }
  let(:exposure) { today - 2 }
  let(:block) do
    { "animal_species" => "dog", "animal_condition" => "healthy", "animal_observable" => "true", "exposure_on" => exposure.iso8601,
      "animal_tutor_name" => "Tutor Marcado Mordida", "animal_tutor_phone" => "41999990000",
      "animal_address" => "Rua das Palmeiras, 45, fundos" }
  end

  after { Current.reset }

  def bite_notification!(disease_code: Zoonoses::Catalog::OBSERVATION_DISEASE, **over)
    notification!(patient: tutor!, disease_code: disease_code, **over)
  end

  def save_form!(notification, form)
    notification.reload
    result = Surveillance::SaveForm.call(notification: notification, form: notification.form.merge(form), version: notification.version,
                                         by: officer)
    expect(result).to be_ok
    notification.reload
  end

  # O consumidor sobre o último evento `name` da notificação (o caminho do
  # IdempotentConsumer, como a fila faria).
  def observe_from!(name, notification)
    event = DomainEvent.where(name: name).where("payload->>'notification_id' = ?", notification.id).order(:occurred_at, :created_at).last
    described_class.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
  end

  def observation_of(notification) = BiteObservation.find_by(disease_notification_id: notification.id)

  it "notificação notified com o bloco cão observável → observação open com ends_on = exposure_on + 10" do
    notification = bite_notification!
    observe_from!("disease_notification.created", notification) # a ficha ainda sem o bloco
    expect(observation_of(notification)).to be_nil

    save_form!(notification, block)
    observe_from!("disease_notification.updated", notification)

    row = observation_of(notification)
    expect(row).to have_attributes(species: "dog", exposure_on: exposure, ends_on: exposure + 10, state: "open", place: "home",
                                   animal_id: nil, outcome: nil, version: 1)
    expect(DomainEvent.where(name: "bite_observation.opened").map(&:payload)).to eq([ { "bite_observation_id" => row.id } ])
  end

  it "gato observável também abre; o created atrasado com a ficha já preenchida age" do
    notification = bite_notification!
    save_form!(notification, block.merge("animal_species" => "cat"))
    observe_from!("disease_notification.created", notification)
    expect(observation_of(notification)).to have_attributes(species: "cat", ends_on: exposure + 10)
  end

  it "possible não age; ao passar a notified, age" do
    notification = bite_notification!(origin: "safety_net")
    expect(notification.status).to eq("possible")
    save_form!(notification, block)
    observe_from!("disease_notification.created", notification)
    observe_from!("disease_notification.updated", notification)
    expect(observation_of(notification)).to be_nil

    result = Surveillance::Transition.call(notification: notification, to: "notified", version: notification.reload.version, by: officer)
    expect(result).to be_ok
    observe_from!("disease_notification.transitioned", notification)
    expect(observation_of(notification)).to have_attributes(state: "open", ends_on: exposure + 10)
  end

  it "investigating age; closed não age" do
    investigating = bite_notification!
    save_form!(investigating, block)
    expect(Surveillance::Transition.call(notification: investigating, to: "investigating", version: investigating.version,
                                         by: officer)).to be_ok
    observe_from!("disease_notification.transitioned", investigating)
    expect(observation_of(investigating)).to be_present

    closed = bite_notification!
    save_form!(closed, block)
    expect(Surveillance::Transition.call(notification: closed, to: "investigating", version: closed.version, by: officer)).to be_ok
    expect(Surveillance::Transition.call(notification: closed, to: "closed", version: closed.reload.version, by: officer,
                                         classification: "confirmed")).to be_ok
    observe_from!("disease_notification.updated", closed)
    observe_from!("disease_notification.transitioned", closed)
    expect(observation_of(closed)).to be_nil
  end

  it "dengue, morcego, observável false, sem exposure_on ou gate desligado → nada" do
    dengue = bite_notification!(disease_code: "dengue")
    observe_from!("disease_notification.created", dengue)

    bat = bite_notification!
    save_form!(bat, block.merge("animal_species" => "bat", "animal_observable" => "false"))
    observe_from!("disease_notification.updated", bat)

    not_observable = bite_notification!
    save_form!(not_observable, block.merge("animal_observable" => "false"))
    observe_from!("disease_notification.updated", not_observable)

    without_exposure = bite_notification!
    save_form!(without_exposure, block.except("exposure_on"))
    observe_from!("disease_notification.updated", without_exposure)

    without_observable = bite_notification!
    save_form!(without_observable, block.except("animal_observable"))
    observe_from!("disease_notification.updated", without_observable)

    off = bite_notification!
    save_form!(off, block)
    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    observe_from!("disease_notification.updated", off)

    expect(BiteObservation.count).to eq(0)
    expect(DomainEvent.where(name: "bite_observation.opened").count).to eq(0)
  end

  it "o mesmo evento duas vezes → uma observação; os três eventos juntos → uma" do
    notification = bite_notification!
    save_form!(notification, block)
    2.times { observe_from!("disease_notification.updated", notification) }
    observe_from!("disease_notification.created", notification)
    expect(Surveillance::Transition.call(notification: notification, to: "investigating", version: notification.version,
                                         by: officer)).to be_ok
    observe_from!("disease_notification.transitioned", notification)

    expect(BiteObservation.where(disease_notification_id: notification.id).count).to eq(1)
    expect(DomainEvent.where(name: "bite_observation.opened").count).to eq(1)
  end

  it "a corrida pelo único da notificação: OpenObservation de novo → nada, sem levantar" do
    notification = bite_notification!
    save_form!(notification, block)
    parameters = Zoonoses::Parameters.current.values
    first = Zoonoses::OpenObservation.call(notification: notification, parameters: parameters)
    expect(first).to be_ok
    expect(first.payload.fetch(:observation)).to be_present
    # O create! que perde a corrida (o exists? já passou) cai no RecordNotUnique.
    allow(BiteObservation).to receive(:exists?).and_return(false)
    again = Zoonoses::OpenObservation.call(notification: notification, parameters: parameters)
    expect(again).to be_ok
    expect(again.payload.fetch(:observation)).to be_nil
    expect(BiteObservation.count).to eq(1)
    expect(DomainEvent.where(name: "bite_observation.opened").count).to eq(1)
  end

  # Review Focus 3.
  it "ficha editada depois (exposure_on novo, observável false) → nada muda na observação aberta; o desfecho segue válido" do
    notification = bite_notification!
    save_form!(notification, block)
    observe_from!("disease_notification.updated", notification)
    row = observation_of(notification)

    save_form!(notification, block.merge("exposure_on" => (today - 1).iso8601))
    observe_from!("disease_notification.updated", notification)
    save_form!(notification, block.merge("exposure_on" => (today - 1).iso8601, "animal_observable" => "false"))
    observe_from!("disease_notification.updated", notification)

    expect(BiteObservation.where(disease_notification_id: notification.id).count).to eq(1)
    expect(row.reload).to have_attributes(exposure_on: exposure, ends_on: exposure + 10, state: "open", version: 1)
    expect(DomainEvent.where(name: "bite_observation.opened").count).to eq(1)

    # O 10º dia (o "hoje" da cidade passado ao comando): o desfecho mede pela exposure_on gravada.
    closed = Zoonoses::CloseObservation.call(observation: row, params: { "outcome" => "healthy", "outcome_on" => row.ends_on.iso8601,
                                                                         "expected_version" => 1 }, by: zoonoses_team!, today: row.ends_on)
    expect(closed).to be_ok
    expect(row.reload).to have_attributes(state: "closed", outcome: "healthy", outcome_on: exposure + 10)
  end

  it "observation_days 15 nos parâmetros → ends_on + 15" do
    ZoonosesParameterVersion.create!(version: 1, values: { "observation_days" => 15 }, created_by_user: zoonoses_coordinator!)
    notification = bite_notification!
    save_form!(notification, block)
    observe_from!("disease_notification.updated", notification)
    expect(observation_of(notification).ends_on).to eq(exposure + 15)
  end
end
