require 'test/unit'
require 'rubygems'
require 'ruby-debug'
require 'ruby2ruby'
require 'mocha'
require 'shoulda'
require 'action_controller'
require 'action_controller/test_process'
require 'active_record'
require 'net/http'
require 'net/https'
require File.join(File.dirname(__FILE__), "..", "lib", "hoptoad_notifier")

RAILS_ROOT = File.join( File.dirname(__FILE__), "fixtures" )

class HoptoadController < ActionController::Base
  def rescue_action e
    raise e
  end
  
  def do_raise
    raise "Hoptoad"
  end
  
  def do_not_raise
    render :text => "Success"
  end
  
  def manual_inform_hoptoad
    inform_hoptoad(Exception.new)
    render :text => "Success"
  end
end

class HoptoadNotifierTest < Test::Unit::TestCase
  def request action = nil, method = :get
    @request = ActionController::TestRequest.new({
      "controller" => "hoptoad",
      "action"     => action ? action.to_s : "",
      "_method"    => method.to_s
    })
    @response = ActionController::TestResponse.new
    @controller.process(@request, @response)
  end
  
  context "HoptoadNotifier configuration" do
    setup do
      @controller = HoptoadController.new
      class ::HoptoadController
        include HoptoadNotifier::Catcher
        def rescue_action e
          rescue_action_in_public e
        end
      end
      assert @controller.private_methods.include?("send_to_hoptoad")
    end

    should "be done with a block" do
      HoptoadNotifier.configure do |config|
        config.host = "host"
        config.port = 3333
        config.secure = true
        config.project_name = "bob"
      end
      
      assert_equal "host", HoptoadNotifier.host
      assert_equal 3333,   HoptoadNotifier.port
      assert_equal true,   HoptoadNotifier.secure
      assert_equal "bob",  HoptoadNotifier.project_name
    end
    
    should "add filters to the backtrace_filters" do
      assert_difference "HoptoadNotifier.backtrace_filters.length" do
        HoptoadNotifier.configure do |config|
          config.filter_backtrace do |line|
            line = "1234"
          end
        end
      end
      
      assert_equal %w( 1234 1234 ), @controller.send(:clean_hoptoad_backtrace, %w( foo bar ))
    end
    
    should "add filters to the params filters" do
      assert_difference "HoptoadNotifier.params_filters.length", 2 do
        HoptoadNotifier.configure do |config|
          config.params_filters << "abc"
          config.params_filters << "def"
        end
      end

      assert HoptoadNotifier.params_filters.include?( "abc" )
      assert HoptoadNotifier.params_filters.include?( "def" )
      
      assert_equal( {:abc => "<filtered>", :def => "<filtered>", :ghi => "789"},
                    @controller.send(:clean_hoptoad_params, :abc => "123", :def => "456", :ghi => "789" ) )
    end
    
    should "add exceptions to the expected-as-404 list" do
      class HNException < Exception; end
      class Not404Exception < Exception; end
      
      assert_difference "HoptoadNotifier.exceptions_for_404.length", 1 do
        HoptoadNotifier.configure do |config|
          config.exceptions_for_404 << HNException
        end
      end

      assert @controller.send( :is_a_404?, HNException.new )
      assert !@controller.send( :is_a_404?, Not404Exception.new )
    end
  end

  context "The hoptoad test controller" do
    setup do
      @controller = ::HoptoadController.new
      class ::HoptoadController
        def rescue_action e
          raise e
        end
      end
    end

    context "with no notifier catcher" do
      should "not prevent raises" do
        assert_raises RuntimeError do
          request("do_raise")
        end
      end

      should "allow a non-raising action to complete" do
        assert_nothing_raised do
          request("do_not_raise")
        end
      end
    end
    
    context "with the notifier installed" do
      setup do
        class ::HoptoadController
          include HoptoadNotifier::Catcher
          def rescue_action e
            rescue_action_in_public e
          end
        end
        assert @controller.private_methods.include?("send_to_hoptoad")
      end
      
      should "prevent raises" do
        @controller.expects(:send_to_hoptoad)
        assert_nothing_raised do
          request("do_raise")
        end
      end

      should "allow a non-raising action to complete" do
        assert_nothing_raised do
          request("do_not_raise")
        end
      end
      
      should "allow manual sending of exceptions" do
        @controller.expects(:send_to_hoptoad)
        assert_nothing_raised do
          request("manual_inform_hoptoad")
        end
      end
    end
  end
  
  context "Sending a notification" do
    context "with an exception" do
      should "send as if it were a normally caugh exception" do
        sender    = HoptoadNotifier::Sender.new
        exception = begin
          raise
        rescue => caught_exception
          caught_exception
        end
        options   = HoptoadNotifier.default_notification_options.merge(:error_message => "123",
                                                                       :backtrace => exception.backtrace)

        HoptoadNotifier::Sender.expects(:new).returns(sender)
        sender.expects(:exception_to_data).with(exception).returns(options)
        sender.expects(:inform_hoptoad).with(options)

        HoptoadNotifier.notify(exception)
      end
    end
    context "without an exception" do
      should "send sensible defaults" do
        sender    = HoptoadNotifier::Sender.new
        backtrace = caller
        options   = HoptoadNotifier.default_notification_options.merge(:error_message => "123",
                                                                       :backtrace => backtrace)
        HoptoadNotifier::Sender.expects(:new).returns(sender)
        sender.expects(:inform_hoptoad).with(options)

        HoptoadNotifier.notify(:error_message => "123", :backtrace => backtrace)
      end
    end
  end

end
