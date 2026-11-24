require "rails_helper"

# Módulo 35b, Task 12 (ADR 0054; contrato §5, §10, §16; decisão 32, Q12, Q16,
# Q26): a fila de observações do animal agressor (/zoonoses/observations),
# para team? (403 missing_role). A lista e o detalhe trazem só o bloco do
# animal (espécie, condição, exposure_on, ends_on, os dias que faltam, estado,
# lugar, versão, animal_id; o detalhe, o desfecho) — nunca o paciente, a
# idade, a unidade, a disease_notification_id nem o contato. O contato (nome,
# telefone do tutor e endereço do animal, da ficha) sai só no GET …/contact,
# com a trilha bite_observation.contact_viewed { bite_observation_id,
# user_id }, Cache-Control: no-store e sem step-up a mais (Q12).
RSpec.describe "Zoonoses — observações do animal agressor", type: :request do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:officer) { surveillance_officer! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:today) { Time.zone.today }
  let(:tutor_name) { "Tutor Marcado Contato" }
  let(:tutor_phone) { "41988887777" }
  let(:animal_address) { "Travessa dos Ipês, 77, casa 2" }

  before do
    Surveillance::DiseaseList::Load.call unless Surveillance::Diseases.find(Zoonoses::Catalog::OBSERVATION_DISEASE)
  end

  def json_post_to(path, fields) = post(path, params: fields.to_json, headers: headers)

  # Notificação do 25 com o bloco do animal na ficha e a observação aberta.
  def observed!(exposure_on: today - 2, **over)
    patient = tutor!
    notification = notification!(patient: patient, disease_code: Zoonoses::Catalog::OBSERVATION_DISEASE, by: officer)
    form = notification.form.merge("animal_species" => "dog", "animal_condition" => "suspect", "animal_observable" => "true",
                                   "exposure_on" => exposure_on.iso8601, "animal_tutor_name" => tutor_name,
                                   "animal_tutor_phone" => tutor_phone, "animal_address" => animal_address)
    expect(Surveillance::SaveForm.call(notification: notification, form: form, version: notification.version, by: officer)).to be_ok
    [ bite_observation!(notification: notification, exposure_on: exposure_on, **over), notification.reload, patient ]
  end

  def secrets(notification, patient)
    [ patient.full_name, patient.cpf, patient.birth_date.to_s, notification.id, notification.health_unit_id,
      notification.health_unit.name, tutor_name, tutor_phone, animal_address ].compact.map(&:to_s)
  end

  it "a lista e o detalhe não trazem nome, CPF, CNS, idade, unidade, notification_id nem o contato (varredura dos valores marcados)" do
    observation, notification, patient = observed!
    closed, = observed!(exposure_on: today - 12, state: "closed")
    sign_in_as(team)

    get "/zoonoses/observations"
    expect(response).to have_http_status(:ok)
    expect(json_body["next_before"]).to be_nil
    expect(json_body["items"].map { _1["id"] }).to eq([ closed.id, observation.id ])
    expect(json_body["items"].last).to eq("id" => observation.id, "species" => "dog", "condition" => "suspect",
                                          "exposure_on" => (today - 2).iso8601, "ends_on" => (today + 8).iso8601, "days_left" => 8,
                                          "state" => "open", "place" => "home", "version" => 1, "animal_id" => nil)
    expect(json_body["items"].first).to include("state" => "closed", "days_left" => nil)
    secrets(notification, patient).each { |secret| expect(response.body).not_to include(secret) }
    %w[patient age cns cpf health_unit_id disease_notification_id animal_tutor_name].each do |key|
      expect(json_body["items"].first).not_to have_key(key)
    end

    get "/zoonoses/observations?state=open"
    expect(json_body["items"].map { _1["id"] }).to eq([ observation.id ])
    get "/zoonoses/observations?state=cancelled"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
    get "/zoonoses/observations?notification_id=#{notification.id}"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])

    get "/zoonoses/observations/#{closed.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => closed.id, "state" => "closed", "outcome" => "healthy",
                                 "outcome_on" => closed.outcome_on.iso8601, "outcome_note" => nil)
    secrets(notification, patient).each { |secret| expect(response.body).not_to include(secret) }
    expect(DomainEvent.where(name: "bite_observation.contact_viewed").count).to eq(0)
  end

  it "GET …/contact publica bite_observation.contact_viewed só com ids, responde no-store e não pede step-up" do
    observation, = observed!
    sign_in_as(team) # sessão sem step-up

    get "/zoonoses/observations/#{observation.id}/contact"
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("animal_tutor_name" => tutor_name, "animal_tutor_phone" => tutor_phone, "animal_address" => animal_address)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(DomainEvent.where(name: "bite_observation.contact_viewed").map(&:payload))
      .to eq([ { "bite_observation_id" => observation.id, "user_id" => team.id } ])

    get "/zoonoses/observations/#{observation.id}/contact?x=1"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/zoonoses/observations/#{SecureRandom.uuid}/contact"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    expect(DomainEvent.where(name: "bite_observation.contact_viewed").count).to eq(1)
  end

  it "POST …/close e …/link_animal gravam e devolvem o detalhe, sem o contato" do
    observation, notification, patient = observed!(exposure_on: today - 10)
    sign_in_as(team)

    dog = animal!
    json_post_to("/zoonoses/observations/#{observation.id}/link_animal", { animal_id: dog.id, expected_version: 1 })
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("animal_id" => dog.id, "version" => 2)

    json_post_to("/zoonoses/observations/#{observation.id}/close", { outcome: "healthy", outcome_on: today.iso8601, expected_version: 1 })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "observation_changed" } ])
    json_post_to("/zoonoses/observations/#{observation.id}/close", { outcome: "healthy", outcome_on: (today - 1).iso8601,
                                                                       expected_version: 2 })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "observation_not_finished", "path" => "outcome_on" } ])
    json_post_to("/zoonoses/observations/#{observation.id}/close", { outcome: "healthy", outcome_on: today.iso8601, expected_version: 2 })
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("state" => "closed", "outcome" => "healthy", "outcome_on" => today.iso8601, "version" => 3,
                                 "days_left" => nil)
    secrets(notification, patient).each { |secret| expect(response.body).not_to include(secret) }

    json_post_to("/zoonoses/observations/#{observation.id}/close?outcome=died", { outcome: "died" })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "stock_keeper → 403; zoonoses desligado → 403 feature_disabled" do
    observation, = observed!
    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    [ "/zoonoses/observations", "/zoonoses/observations/#{observation.id}", "/zoonoses/observations/#{observation.id}/contact" ].each do |path|
      get path
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
    json_post_to("/zoonoses/observations/#{observation.id}/close", { outcome: "died", outcome_on: today.iso8601, expected_version: 1 })
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    expect(DomainEvent.where(name: "bite_observation.contact_viewed").count).to eq(0)

    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(team)
    get "/zoonoses/observations"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "zoonoses" } ])
  end
end
