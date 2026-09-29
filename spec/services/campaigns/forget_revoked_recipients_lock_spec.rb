require "rails_helper"

# Corrida entre o congelamento (DispatchJob) e o esquecimento por revogação:
# os dois pegam a mesma trava de transação (RecipientsFreezeLock). Sem fixture
# transacional: uma thread com conexão própria segura a trava e outra roda o
# ForgetRevokedRecipients. O dado da segunda (cidadão e conversa) fica dentro
# da transação dela e volta com Rollback, então nada commita e não sobra resíduo.
RSpec.describe Campaigns::ForgetRevokedRecipients, "trava do congelamento" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let!(:created_city) { City.find_by(slug: TEST_CITY_A.slug).nil? }
  let!(:city_record) { register_test_city! }

  after do
    release << true
    threads.each { |t| t.join(5) || t.kill }
  ensure
    city_record.destroy if created_city
  end

  it "espera quem congela o público e segue quando ele solta a trava" do
    held = Queue.new
    threads << holder = Thread.new do
      CityConnection.with(TEST_CITY_A) do
        ApplicationRecord.transaction do
          Campaigns::RecipientsFreezeLock.acquire!
          held << true
          release.pop(timeout: 10)
        end
      end
    end
    held.pop(timeout: 5) or raise "a thread do congelamento não pegou a trava"

    finished = Queue.new
    threads << forgetter = Thread.new do
      CityConnection.with(TEST_CITY_A) do
        ApplicationRecord.transaction do
          citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
          convo = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "revoked")
          described_class.call(conversation_id: convo.id)
          finished << true
          raise ActiveRecord::Rollback
        end
      end
    end

    expect(wait_for_lock_wait).to be(true) # o esquecimento está parado na trava
    expect(finished.size).to eq(0)

    release << true
    expect(holder.join(5)).to be(holder)
    expect(finished.pop(timeout: 5)).to be(true)
    expect(forgetter.join(5)).to be(forgetter)
    expect(CityConnection.with(TEST_CITY_A) { Citizen.where(cpf: "52998224725").count }).to eq(0)
  end
end
