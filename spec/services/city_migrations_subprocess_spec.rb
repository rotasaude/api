require "rails_helper"

# Dentro do worker a migração da cidade não pode trocar a conexão de
# ActiveRecord::Base (o Solid Queue usa a mesma): roda em outro processo.
RSpec.describe CityMigrations::Subprocess do
  let(:city) { create(:city, slug: "subproc#{SecureRandom.hex(3)}", status: "provisioning") }

  it "runs city:migrate for the slug in a separate rails process and returns the reloaded city" do
    status = instance_double(Process::Status, success?: true, exitstatus: 0)
    expect(Open3).to receive(:capture2e)
      .with({ "RAILS_ENV" => Rails.env }, Rails.root.join("bin/rails").to_s, "city:migrate[#{city.slug}]",
            chdir: Rails.root.to_s)
      .and_return([ "[city:migrate] ok", status ])

    expect(described_class.call(city)).to eq(city)
  end

  it "raises with the tail of the output, credentials redacted, when the task fails" do
    status = instance_double(Process::Status, success?: false, exitstatus: 1)
    allow(Open3).to receive(:capture2e).and_return([ "boom em postgres://rota_city_x:s3gr3d0@db/x\n", status ])

    expect { described_class.call(city) }.to raise_error(CityMigrations::Subprocess::Failed) { |error|
      expect(error.message).to include(city.slug).and include("://***@")
      expect(error.message).not_to include("s3gr3d0")
    }
  end
end
