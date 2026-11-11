require "rails_helper"

# Módulo 33 (ADR 0051; Q33, Q35, Q43): a tabela de status das recusas. A base
# só carrega com o portão da ouvidoria; as ações chegam com as rotas.
RSpec.describe Ombudsman::BaseController do
  it "inclui o portão da ouvidoria e exige a ouvidoria ligada antes de tudo" do
    expect(described_class.ancestors).to include(OmbudsmanGate, Authentication, MfaStepUp)
    expect(described_class._process_action_callbacks.map(&:filter)).to include(:require_ombudsman!)
  end

  it "fixa os status das recusas (409/403/404/410/429; o resto, 422)" do
    status = described_class::FAILURE_STATUS
    %i[manifestation_changed forwarding_changed already_answered reopen_pending already_decided report_published already_published].each do |reason|
      expect(status.fetch(reason)).to eq(:conflict)
    end
    expect(status.values_at(:missing_role, :not_own_citizen)).to all(eq(:forbidden))
    expect(status.fetch(:not_found)).to eq(:not_found)
    expect(status.fetch(:link_expired)).to eq(:gone)
    expect(status.values_at(:too_many_requests, :daily_cap_reached)).to all(eq(:too_many_requests))
    expect(status.keys).not_to include(:rate_limited, :forwarding_not_pending)
  end
end
