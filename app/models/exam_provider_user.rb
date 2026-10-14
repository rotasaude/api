# Usuário do portal do prestador (papel exam_provider): um prestador por usuário.
class ExamProviderUser < ApplicationRecord
  belongs_to :exam_provider
  belongs_to :user
end
