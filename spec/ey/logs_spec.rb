require 'spec_helper'

describe "ey logs" do
  given "integration"

  it "prints logs returned by awsm" do
    login_scenario "one app, one environment"
    fast_ey %w[logs -e giblets]
    @out.should match(/MAIN LOG OUTPUT/)
    @out.should match(/CUSTOM LOG OUTPUT/)
    @err.should == ''
  end

  it "complains when it can't infer the environment" do
    login_scenario "one app, many environments"
    fast_failing_ey %w[logs]
    @err.should =~ /Multiple environments possible, please be more specific/i
  end
end

describe "ey logs" do
  given "integration"

  def command_to_run(opts)
    cmd = ["logs"]
    cmd << "--environment" << opts[:environment] if opts[:environment]
    cmd << "--account"     << opts[:account]     if opts[:account]
    cmd
  end

  def verify_ran(scenario)
    @out.should match(/Main logs for #{scenario[:environment]}/)
  end

  include_examples "it takes an environment name and an account name"
end
