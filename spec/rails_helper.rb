# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
# FORÇADO (não ||=): o container roda com RAILS_ENV=development; sem isto o rspec
# conectaria no banco de DEV e specs não-transacionais (limpeza via DELETE)
# apagariam dados reais. Specs sempre rodam em test.
ENV['RAILS_ENV'] = 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is deployed (production or staging)
abort("The Rails environment is running in a deployed mode (#{Rails.env})!") if Rota.deployed?
abort("Specs must run in the test environment, got #{Rails.env}") unless Rails.env.test?
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
require 'rspec/rails'
require 'factory_bot_rails'
require_relative "support/city_probe_controller"
require_relative "support/city_database_urls"
require_relative "support/scratch_databases"
require_relative "support/provisioned_cities"
require_relative "support/platform_queue"
require_relative "support/city_test_databases"
require_relative "support/city_request_auth"
require_relative "support/protocol_signatures"
require_relative "support/maintenance_city_mutations"
require_relative "support/triage_protocol_helpers"
require_relative "support/citizen_request_helpers"
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
# Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# Nota: `primary`/`city_unset` em test apontam para o banco vazio
# rota_saude_no_city_selected (Plano 5), dono do database é o superusuário
# rota_saude — rota_app (role do app) não tem permissão de dono, por isso
# maintain_test_schema! falha ao tentar db:test:purge nele. Não há domínio nem
# migrations em db/migrate/ (banco por cidade, Plano 2): plataforma migra via
# `platform` (db:migrate:platform) e cada cidade via city:migrate:all, fora
# desse fluxo. Suprimimos o check aqui.
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  # rspec-rails só limpa CurrentAttributes em example groups tipados
  # (RailsExampleGroup). Specs sem `type:` herdariam Current.city do
  # exemplo anterior, mascarando dependência de ordem. `around` (e não `before`)
  # porque config arounds envolvem os `around` dos arquivos, que setam Current.
  config.around(:each) do |example|
    ActiveSupport::CurrentAttributes.clear_all
    example.run
  ensure
    ActiveSupport::CurrentAttributes.clear_all
  end

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
