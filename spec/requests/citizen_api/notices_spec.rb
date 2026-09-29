# spec/requests/citizen_api/notices_spec.rb
require "rails_helper"

RSpec.describe "Caixa de avisos do cidadão", type: :request do
  def body = JSON.parse(response.body)

  let(:phone) { "+5541998765432" }
  let!(:ana) { person!(phone: phone, cpf: "52998224725") }

  def notice!(citizen, title:, at: 1.hour.ago)
    recipient!(sent_campaign!(title: title, dispatched_at: at), citizen, sms_status: "not_opted_in")
  end

  it "lista os avisos do telefone, mais novo primeiro; uma pessoa só: sem cpf_masked" do
    older = notice!(ana, title: "Aviso antigo", at: 2.days.ago)
    newer = notice!(ana, title: "Aviso novo")
    notice!(person!, title: "De outro telefone")
    sign_in_citizen(phone)

    get "/citizen/notices"
    expect(body["notices"].map { |n| n["id"] }).to eq([ newer.id, older.id ])
    expect(body["notices"].first).to eq(
      "id" => newer.id, "title" => "Aviso novo", "body" => newer.campaign.body,
      "dispatched_at" => newer.campaign.reload.dispatched_at.iso8601, "read" => false, "cpf_masked" => nil
    )
    expect(body["unread_count"]).to eq(2)
  end

  it "telefone com duas pessoas: avisos das duas, cada um com o cpf_masked da pessoa" do
    bia = person!(phone: phone, cpf: "11144477735")
    notice!(ana, title: "Para Ana")
    notice!(bia, title: "Para Bia", at: 2.hours.ago)
    sign_in_citizen(phone)
    get "/citizen/notices"
    expect(body["notices"].map { |n| [ n["title"], n["cpf_masked"] ] })
      .to eq([ [ "Para Ana", ana.cpf_masked ], [ "Para Bia", bia.cpf_masked ] ])
  end

  it "marcar lido: conta cai; marcar lido duas vezes responde ok sem erro" do
    row = notice!(ana, title: "Aviso novo")
    sign_in_citizen(phone)
    2.times do
      json_post "/citizen/notices/#{row.id}/read"
      expect(body).to eq("ok" => true)
    end
    expect(row.reload.notice_read_at).to be_present
    get "/citizen/notices"
    expect(body["unread_count"]).to eq(0)
    expect(body["notices"].first["read"]).to be(true)
  end

  it "aviso de outro telefone, ou id que não é UUID: 404 e nada muda" do
    foreign = notice!(person!, title: "De outro telefone")
    sign_in_citizen(phone)
    [ foreign.id, "nao-e-uuid" ].each do |id|
      json_post "/citizen/notices/#{id}/read"
      expect(response).to have_http_status(:not_found)
    end
    expect(foreign.reload.notice_read_at).to be_nil
  end

  it "silenciar tira do contador só a pessoa silenciada; os avisos continuam na lista" do
    bia = person!(phone: phone, cpf: "11144477735")
    notice!(ana, title: "Para Ana")
    notice!(bia, title: "Para Bia")
    Citizens::UpdateContactPreferences.call(citizen: bia, changes: { "notices_muted" => true })
    sign_in_citizen(phone)
    get "/citizen/notices"
    expect(body["notices"].size).to eq(2)
    expect(body["unread_count"]).to eq(1)
  end

  it "sem sessão: 401; escrita sem JSON: 415" do
    get "/citizen/notices"
    expect(response).to have_http_status(:unauthorized)
    sign_in_citizen(phone)
    post "/citizen/notices/#{notice!(ana, title: 'Aviso novo').id}/read"
    expect(response).to have_http_status(:unsupported_media_type)
  end

  it "não faz N+1: o número de consultas não cresce com os avisos" do
    notice!(ana, title: "Aviso um")
    sign_in_citizen(phone)
    count = lambda do
      n = 0
      cb = ->(*, payload) { n += 1 unless payload[:name] == "SCHEMA" || payload[:sql] =~ /\A\s*(SAVEPOINT|RELEASE|BEGIN|COMMIT)/ }
      ActiveSupport::Notifications.subscribed(cb, "sql.active_record") { get "/citizen/notices" }
      n
    end
    count.call
    before = count.call
    3.times { |i| notice!(ana, title: "Mais #{i}") }
    expect(count.call).to eq(before)
  end
end
