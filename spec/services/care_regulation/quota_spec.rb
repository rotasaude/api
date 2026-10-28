require "rails_helper"

# Módulo 26a (contrato §13 G1): o usado é a contagem das autorizações não
# liberadas da oferta; o disponível nunca é negativo.
RSpec.describe CareRegulation::Quota do
  before { regulation_city! }

  let(:admin) { regulation_admin! }
  let(:provider) { external_provider! }

  def authorize!(offer, released: false)
    RegulationAuthorization.create!(
      regulation_request: regulation_request!(status: "pending"), care_offer: offer, authorized_by_user: admin, month: offer.month,
      released_at: (released ? Time.current : nil), release_reason: (released ? "cancelled" : nil)
    )
  end

  it "used conta só as não liberadas, por oferta, e devolve 0 para a oferta sem autorização" do
    one = offer!(provider: provider, quantity: 5)
    two = offer!(provider: provider, target_code: "225250", quantity: 5)
    empty = offer!(provider: provider, target_code: "225124", quantity: 5)
    2.times { authorize!(one) }
    authorize!(one, released: true)
    authorize!(two)

    expect(described_class.used([ one.id, two.id, empty.id ])).to eq(one.id => 2, two.id => 1, empty.id => 0)
    expect(described_class.used([])).to eq({})
  end

  it "used faz uma consulta só" do
    ids = 3.times.map { |i| offer!(provider: provider, target_code: %w[225120 225250 225124][i]).id }
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("regulation_authorizations") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.used(ids) }
    expect(queries.size).to eq(1)
  end

  it "available é quantity - used e nunca negativo" do
    offer = offer!(provider: provider, quantity: 2)
    expect(described_class.available(offer, used: 0)).to eq(2)
    expect(described_class.available(offer, used: 2)).to eq(0)
    expect(described_class.available(offer, used: 3)).to eq(0)
  end
end
