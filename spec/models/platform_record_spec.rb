require "rails_helper"

RSpec.describe PlatformRecord do
  it "is abstract and connects to the platform database" do
    expect(described_class.abstract_class?).to be(true)
    name = described_class.connection_db_config.database
    expect(name).to match(/platform/)
  end

  it "does not share a connection with ApplicationRecord" do
    expect(described_class.connection_db_config.database)
      .not_to eq(ApplicationRecord.connection_db_config.database)
  end
end
