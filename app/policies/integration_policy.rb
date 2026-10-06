# app/policies/integration_policy.rb
# Integrações e CNES da cidade (ADR 0028): só o municipal_admin.
class IntegrationPolicy < ApplicationPolicy
  def manage? = role?(:municipal_admin)
end
