require "rails_helper"

RSpec.describe "Active Storage na plataforma" do
  it "grava o blob no banco da plataforma sem cidade corrente" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "a.png", content_type: "image/png",
                                                  identify: false, metadata: { analyzed: true })
    expect(ActiveStorage::Blob.connection_db_config.name).to eq("platform")
    expect(ActiveStorage::Blob.find(blob.id)).to be_present
  end

  it "grava na plataforma mesmo dentro de CityConnection.with" do
    id = CityConnection.with(TEST_CITY_A) { ActiveStorage::Blob.create_and_upload!(io: StringIO.new("y"), filename: "b.png", content_type: "image/png", identify: false, metadata: { analyzed: true }).id }
    expect(ActiveStorage::Blob.find(id)).to be_present
  end
end

RSpec.describe "Rotas do Active Storage", type: :request do
  it "não desenha /rails/active_storage" do
    expect { Rails.application.routes.recognize_path("/rails/active_storage/blobs/redirect/x/y") }
      .to raise_error(ActionController::RoutingError)
  end
end
