require "rails_helper"

RSpec.describe TenantScopedJob do
  let(:test_job_class) do
    Class.new(ApplicationJob) do
      include TenantScopedJob
      def perform(municipality_id)
        with_tenant(municipality_id) do
          ApplicationRecord.connection.select_value("SELECT current_setting('app.municipality_id')")
        end
      end
    end
  end

  it "seta SET LOCAL dentro do bloco" do
    muni_id = SecureRandom.uuid
    result = test_job_class.new.perform(muni_id)
    expect(result).to eq(muni_id)
  end

  it "sem municipality_id levanta TenantMissing" do
    expect { test_job_class.new.perform(nil) }.to raise_error(TenantScopedJob::TenantMissing)
  end
end
