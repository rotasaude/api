require "rails_helper"

RSpec.describe OtpChallenge do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset; travel_back }

  let(:phone) { "+5541998765432" }

  it "emite um código de 6 dígitos e guarda só o hash" do
    challenge, code = described_class.issue!(phone: phone)
    expect(code).to match(/\A\d{6}\z/)
    expect(challenge.code_digest).not_to include(code)
  end

  it "aceita o código certo uma vez só" do
    _, code = described_class.issue!(phone: phone)
    expect(described_class.verify(phone: phone, code: code)).to eq(:ok)
    expect(described_class.verify(phone: phone, code: code)).to eq(:missing)
  end

  it "recusa o código de um telefone usado em outro" do
    _, code = described_class.issue!(phone: phone)
    expect(described_class.verify(phone: "+5541911112222", code: code)).to eq(:missing)
  end

  it "conta tentativas erradas e esgota na quinta" do
    _, code = described_class.issue!(phone: phone)
    wrong = code == "000000" ? "111111" : "000000"
    5.times { expect(described_class.verify(phone: phone, code: wrong)).to eq(:invalid) }
    expect(described_class.verify(phone: phone, code: code)).to eq(:exhausted)
  end

  it "vence em 10 minutos" do
    _, code = described_class.issue!(phone: phone)
    travel 11.minutes
    expect(described_class.verify(phone: phone, code: code)).to eq(:expired)
  end

  it "só reenvia depois de 60 s" do
    described_class.issue!(phone: phone)
    expect { described_class.issue!(phone: phone) }.to raise_error(OtpChallenge::TooSoon)
    travel 61.seconds
    expect { described_class.issue!(phone: phone) }.not_to raise_error
  end

  it "envia no máximo 5 códigos por telefone em 24 h" do
    5.times do
      described_class.issue!(phone: phone)
      travel 61.seconds
    end
    expect { described_class.issue!(phone: phone) }.to raise_error(OtpChallenge::DailyLimit)
    travel 24.hours
    expect { described_class.issue!(phone: phone) }.not_to raise_error
  end

  it "toma um advisory lock por telefone dentro da transação, sem o telefone na SQL" do
    executed_sql = []
    allow(described_class.connection).to receive(:execute).and_wrap_original do |original, sql, *args|
      executed_sql << sql
      original.call(sql, *args)
    end

    described_class.issue!(phone: phone)

    lock_statements = executed_sql.select { |sql| sql.include?("pg_advisory_xact_lock") }
    expect(lock_statements).not_to be_empty
    expect(lock_statements).to all(match(/pg_advisory_xact_lock\(-?\d+\)/))
    expect(executed_sql.join(" ")).not_to include("998765432")
  end

  it "vale o código mais recente: um reenvio invalida o anterior" do
    _, first = described_class.issue!(phone: phone)
    travel 61.seconds
    _, second = described_class.issue!(phone: phone)
    skip "códigos coincidiram" if first == second
    expect(described_class.verify(phone: phone, code: first)).to eq(:invalid)
    expect(described_class.verify(phone: phone, code: second)).to eq(:ok)
  end
end
