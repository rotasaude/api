require "rails_helper"

# F-12.4: o congelamento do público (DispatchJob) toma a mesma trava de
# transação que o esquecimento por revogação (RecipientsFreezeLock). O outro
# lado (ForgetRevokedRecipients esperando) está em
# spec/services/campaigns/forget_revoked_recipients_lock_spec.rb.
#
# Threads reais, sem fixture transacional: uma thread segura a trava (como uma
# revogação em curso) e outra roda o DispatchJob. O dado da segunda (autor,
# cidadãos, campanha) fica dentro da transação dela — o with_city do job reentra
# a mesma conexão e vira savepoint — e volta com Rollback: nada commita.
RSpec.describe Campaigns::DispatchJob, "trava do congelamento" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let!(:created_city) { City.find_by(slug: TEST_CITY_A.slug).nil? }
  let!(:city_record) { register_test_city! }

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
  ensure
    city_record.destroy if created_city
  end

  it "espera quem segura a trava (revogação em curso) e só congela depois que ela solta" do
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
    held.pop(timeout: 5) or raise "a thread da revogação não pegou a trava"

    ready = Queue.new
    finished = Queue.new
    threads << dispatcher = Thread.new do
      CityConnection.with(TEST_CITY_A) do
        ApplicationRecord.transaction do
          5.times { person! }
          campaign = draft_campaign!
          campaign.update_columns(status: "sending", dispatched_by_user_id: campaign.created_by_user_id)
          ready << true
          described_class.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
          finished << [ campaign.reload.status, CampaignRecipient.where(campaign_id: campaign.id).count ]
          raise ActiveRecord::Rollback
        end
      end
    end
    ready.pop(timeout: 5) or raise "o dispatch não chegou a rodar"

    expect(wait_for_lock_wait).to be(true) # o congelamento está parado na trava
    expect(finished.size).to eq(0)

    release << true
    expect(holder.join(5)).to be(holder)
    expect(finished.pop(timeout: 5)).to eq([ "sent", 5 ])
    expect(dispatcher.join(5)).to be(dispatcher)
  end
end
