require "rails_helper"

RSpec.describe CitizenSession do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset; travel_back }

  it "guarda só o hash do token e retoma a sessão pelo token" do
    session, token = described_class.start!(phone: "+5541998765432")
    expect(session.token_digest).not_to eq(token)
    expect(described_class.resume(token)).to eq(session)
    expect(described_class.resume("outro")).to be_nil
    expect(described_class.resume(nil)).to be_nil
  end

  it "expira em 30 dias sem uso e desliza o prazo quando usada" do
    session, token = described_class.start!(phone: "+5541998765432")
    travel 29.days
    expect(described_class.resume(token)).to eq(session)
    travel 29.days
    expect(described_class.resume(token)).to eq(session)
    travel 31.days
    expect(described_class.resume(token)).to be_nil
  end

  it "não retoma sessão revogada" do
    session, token = described_class.start!(phone: "+5541998765432")
    session.revoke!
    expect(described_class.resume(token)).to be_nil
  end

  it "lista as pessoas do telefone da sessão, e só elas" do
    session, = described_class.start!(phone: "+5541998765432")
    mine = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    Citizen.create!(cpf: "52998224725", phone: "+5541911112222")
    expect(session.citizens).to contain_exactly(mine)
  end
end
