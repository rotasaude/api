require "rails_helper"

# Módulo 35b, Task 11 (contrato §5, Q7, Q16): o bloco do animal na ficha do 25 e a volta da
# observação à notificação (só leitura: o 25 não grava nada do 35b).
RSpec.describe "Vigilância — bloco do animal e observação na notificação", type: :request do
  let!(:city) { surveillance_city! }
  let(:officer) { surveillance_officer! }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:animal) do
    { animal_species: "dog", animal_condition: "healthy", animal_observable: "true", exposure_on: Time.zone.today.iso8601,
      animal_tutor_name: "Tutor Fulano", animal_tutor_phone: "41999990000", animal_address: "Rua das Flores, 100" }
  end

  before do
    Surveillance::DiseaseList::Load.call unless Surveillance::Diseases.find("acidente_animal_raiva")
    sign_in_as(officer)
  end

  def bite_notification!(seq)
    notification!(patient: surveillance_patient!(seq), disease_code: "acidente_animal_raiva")
  end

  def patch_form(notification, form)
    patch "/surveillance/notifications/#{notification.id}", params: { form: form, version: notification.version }.to_json,
                                                            headers: json_headers
  end

  it "PATCH da ficha com o bloco grava cifrado; o detalhe traz animal_observation null" do
    notification = bite_notification!(71)
    patch_form(notification, animal)
    expect(response).to have_http_status(:ok)
    expect(json_body["form"]).to include("animal_species" => "dog", "animal_tutor_phone" => "41999990000")
    expect(json_body["animal_observation"]).to be_nil
    raw = DiseaseNotification.connection.select_value("SELECT form FROM disease_notifications WHERE id = '#{notification.id}'")
    expect(raw).not_to include("Tutor Fulano")
    expect(raw).not_to include("Rua das Flores")
    get "/surveillance/notifications/#{notification.id}"
    expect(json_body["animal_observation"]).to be_nil
    expect(json_body["form"]["animal_tutor_name"]).to eq("Tutor Fulano")
  end

  it "bloco em outra doença → 422 invalid_form com path form.animal_species" do
    dengue = notification!(patient: surveillance_patient!(72), disease_code: "dengue")
    patch_form(dengue, { animal_species: "dog" })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_form")
    expect(json_body).to eq("error" => "invalid_form", "path" => "form.animal_species")
  end

  it "detalhe com observação traz animal_observation; fechada e notified → fila com animal_outcome_pending true; fechada a notificação → false" do
    notification = bite_notification!(73)
    observation = bite_observation!(notification: notification, state: "closed")
    get "/surveillance/notifications/#{notification.id}"
    expect(json_body["animal_observation"]).to eq("state" => "closed", "ends_on" => observation.ends_on.iso8601,
                                                  "outcome" => "healthy", "outcome_on" => observation.outcome_on.iso8601)
    expect(json_body["animal_outcome_pending"]).to be(true)
    get "/surveillance/notifications"
    expect(json_body["notifications"].find { |n| n["id"] == notification.id }).to include("animal_outcome_pending" => true)
    notification.update_columns(status: "closed", classification: "confirmed", closed_at: Time.current)
    get "/surveillance/notifications?status=closed"
    expect(json_body["notifications"].find { |n| n["id"] == notification.id }).to include("animal_outcome_pending" => false)
  end

  it "observação aberta não é pendente" do
    notification = bite_notification!(74)
    bite_observation!(notification: notification)
    get "/surveillance/notifications"
    expect(json_body["notifications"].first).to include("animal_outcome_pending" => false)
  end

  it "a fila do 25 com 50 notificações faz as mesmas consultas com e sem observação" do
    notifications = Array.new(50) { |i| bite_notification!(100 + i) }
    count_queries = lambda do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/)
      end
      begin
        get "/surveillance/notifications?limit=100"
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      expect(json_body["notifications"].size).to eq(50)
      statements.size
    end
    count_queries.call # aquece os caches de processo (doenças, ajustes)
    without = count_queries.call
    notifications.each { |n| bite_observation!(notification: n, state: "closed") }
    with = count_queries.call
    expect(json_body["notifications"]).to all(include("animal_outcome_pending" => true))
    expect(with).to eq(without)
  end
end
