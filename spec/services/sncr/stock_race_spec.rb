# spec/services/sncr/stock_race_spec.rb
require "rails_helper"

# Review Focus 3 (ADR 0034, "um número SNCR nunca é usado duas vezes"): duas
# emissões ao mesmo tempo em conexões reais. Quem chega segundo pula o número
# travado (SKIP LOCKED) sem esperar: com 2 livres pega o outro; com 1, nil
# (a receita dele sai em papel com no_sncr_number).
RSpec.describe "Corrida no estoque SNCR" do
  self.use_transactional_tests = false

  let(:city) { TEST_CITY_A }
  let(:entered) { Queue.new }
  let(:release) { Queue.new }
  let(:threads) { [] }

  before do
    @user = CityConnection.with(city) do
      User.create!(email_address: "sncr-corrida-#{SecureRandom.hex(4)}@cidade.gov.br", password: "senha-segura-123")
    end
  end

  after do
    3.times { release << true }
    threads.each { |thread| (thread.join(5) rescue nil) || thread.kill }
    CityConnection.with(city) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        SncrNumber.where(user_id: @user.id).delete_all
        SncrNumberBatch.where(user_id: @user.id).delete_all
        DomainEvent.where("payload->>'user_id' = ?", @user.id).delete_all
        User.where(id: @user.id).delete_all
      end
    end
  end

  def stock!(count)
    CityConnection.with(city) do
      first = "2610.1-41.#{format('%07d', 1)}"
      last = "2610.1-41.#{format('%07d', count)}"
      Sncr::Stock.record_batch!(user: @user, kind: "rce", block: Sncr::Client::Block.new(first: first, last: last, quantity: count),
                                simulated: true)
    end
  end

  def holder
    track(Thread.new do
      CityConnection.with(city) do
        ApplicationRecord.transaction do
          taken = Sncr::Stock.take!(user: @user, kind: "rce", simulated: true)
          entered << true
          release.pop(timeout: 5)
          taken&.number
        end
      end
    end)
  end

  def second
    track(Thread.new do
      CityConnection.with(city) do
        ApplicationRecord.transaction { Sncr::Stock.take!(user: @user, kind: "rce", simulated: true)&.number }
      end
    end)
  end

  def track(thread) = thread.tap { threads << thread }

  it "com 2 livres: o segundo pega o outro, sem esperar" do
    stock!(2)
    first = holder
    expect(entered.pop(timeout: 5)).to be(true)
    other = second
    expect(other.join(5)).to be_truthy
    expect(first).to be_alive
    release << true
    expect([ first.value, other.value ]).to eq(%w[2610.1-41.0000001 2610.1-41.0000002])
  end

  it "com 1 livre: o segundo recebe nil na hora (papel), nunca o mesmo número" do
    stock!(1)
    first = holder
    expect(entered.pop(timeout: 5)).to be(true)
    other = second
    expect(other.join(5)).to be_truthy
    expect(other.value).to be_nil
    release << true
    expect(first.value).to eq("2610.1-41.0000001")
  end
end
