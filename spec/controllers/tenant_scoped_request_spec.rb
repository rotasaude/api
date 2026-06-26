require "rails_helper"

class FakeController < ApplicationController
  include Authentication
  # prepend_before_action runs BEFORE the inherited around_action :within_tenant,
  # so we can set Current.session before current_municipality needs Current.user.
  prepend_before_action :set_test_session

  cattr_accessor :test_session_store

  def set_test_session
    Current.session = self.class.test_session_store if self.class.test_session_store
  end

  def index
    render json: { tenant: ApplicationRecord.connection.select_value("SELECT current_setting('app.municipality_id')") }
  end
end

RSpec.describe "TenantScopedRequest", type: :request do
  before(:all) do
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw do
      get "/fake_index", to: "fake#index"
    end
    Rails.application.routes.finalize!
  end

  after(:all) do
    Rails.application.routes.disable_clear_and_finalize = false
    Rails.application.reload_routes!
  end

  after { Current.reset }

  let!(:user) { User.create!(email_address: "x@example.org", password: "secret123") }
  let!(:muni) { create(:municipality) }
  let!(:membership) { Membership.create!(user: user, municipality: muni, role: "viewer", granted_at: Time.current) }

  before do
    @session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    FakeController.test_session_store = @session
    allow_any_instance_of(FakeController).to receive(:resume_session) { Current.session = @session }
  end

  after do
    FakeController.test_session_store = nil
  end

  it "resolve tenant do único membership do usuário" do
    get "/fake_index"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["tenant"]).to eq(muni.id)
  end
end
