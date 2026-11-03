require "rails_helper"

# Módulo 30, Task 3 (ADR 0048; contrato §14 T18): o agendamento externo pode
# apontar o prestador (care_provider_id); o prestador ganha o município (IBGE).
RSpec.describe CareRegulation::ScheduleExternal, "com prestador" do
  before { regulation_city! }

  let(:regulator) { regulation_regulator! }
  let(:at) { (Time.current + 5.days).iso8601 }

  def schedule(request, **over)
    described_class.call(request: request, at: at, place: "Clínica", notes: nil, version: request.version, by: regulator, **over)
  end

  it "grava a coluna e o JSON traz schedule.care_provider { id, name }" do
    provider = external_provider!(name: "Hospital de Olhos")
    request = regulation_request!(status: "external")
    expect(schedule(request, care_provider_id: provider.id)).to be_ok
    expect(request.reload.care_provider_id).to eq(provider.id)
    expect(CareRegulation::Json.request(request).fetch(:schedule)).to include(care_provider: { id: provider.id, name: "Hospital de Olhos" })
  end

  it "prestador próprio, inativo, inexistente ou malformado → invalid_request path care_provider_id, nada muda" do
    own = own_provider!(create_unit("UBS Própria"))
    inactive = external_provider!.tap { |p| p.update!(active: false, updated_by_user: regulator) }
    [ own.id, inactive.id, SecureRandom.uuid, 123 ].each do |bad|
      request = regulation_request!(status: "external")
      result = schedule(request, care_provider_id: bad)
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "care_provider_id" ])
      expect(request.reload.status).to eq("external")
      expect(request.care_provider_id).to be_nil
    end
  end

  it "sem a chave, tudo como antes: coluna nula e schedule.care_provider nulo" do
    request = regulation_request!(status: "external")
    expect(schedule(request)).to be_ok
    expect(request.reload.care_provider_id).to be_nil
    expect(CareRegulation::Json.request(request).fetch(:schedule)).to include(care_provider: nil)
  end

  it "remarcar com outro prestador troca a coluna" do
    first = external_provider!
    second = external_provider!(kind: "consortium")
    request = regulation_request!(status: "external")
    schedule(request, care_provider_id: first.id)
    schedule(request.reload, care_provider_id: second.id)
    expect(request.reload.care_provider_id).to eq(second.id)
  end
end
