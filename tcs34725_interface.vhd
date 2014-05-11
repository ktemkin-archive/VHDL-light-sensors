-- The MIT License (MIT)
-- 
-- Copyright (c) 2014 Kyle J. Temkin <ktemkin@binghamton.edu>
-- Copyright (c) 2014 Binghamton University
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this firmware and associated documentation files (the "firmware"), to deal
-- in the firmware without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the firmware, and to permit persons to whom the firmware is
-- furnished to do so, subject to the following conditions:
-- 
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the firmware.
-- 
-- THE FIRMWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE FIRMWARE OR THE USE OR OTHER DEALINGS IN
-- THE FIRMWARE.

--
-- Simple TCS34725 interface.
--


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tcs34725_interface is
  generic(

    --The clock frequency of the board you're using.
    --For the Basys board, this is usually 50MHz, or 50_000_000.
    clk_frequency : integer := 50_000_000;

    --The I2C clock frequency. This can be any number below 400kHz for
    --the TCS34725.
    i2c_frequency : integer := 100_000
  );
  port(

    --System clock.
    clk   : in std_logic;
    reset : in std_logic := '0';
    
    --I2C signals.
    sda : inout std_logic;
    scl : inout std_logic;

    --Light sensor reading...
    clear_intensity : out std_logic_vector(15 downto 0);
    red_intensity   : out std_logic_vector(15 downto 0);
    green_intensity : out std_logic_vector(15 downto 0);
    blue_intensity  : out std_logic_vector(15 downto 0)
  );
end tcs34725_interface;

architecture Behavioral of tcs34725_interface is

  --The address of the TCS34725. This device has only one possible address,
  --so we won't genericize it.
  constant address : std_logic_vector := "0101001";

  --Signals for data exchange with the core I2C controller.
  signal data_to_write, last_read_data : std_logic_vector(7 downto 0);
  signal reading, transaction_active, controller_in_use : std_logic;

  --Rising edge detect for the "controller in use" signal.
  --A rising edge of this signal indicates that the I2C controller has accepted our data.
  signal controller_was_in_use    : std_logic;
  signal controller_accepted_data, new_data_available : std_logic;

  --I2C read/write constants.
  constant write : std_logic := '0';
  constant read  : std_logic := '1';

  --I2C commands for the TSL34725.
  constant select_control_register : std_logic_vector := x"80";
  constant power_on                : std_logic_vector := x"03";
  constant read_color_values       : std_logic_vector := x"B4";

  --Core state machine logic.
  type state_type is (STARTUP, SEND_POWER_COMMAND, TURN_POWER_ON,
                      WAIT_BEFORE_READING, SEND_READ_COMMAND, START_READ, 
                      FINISH_READ_AND_CONTINUE, FINISH_READ_AND_RESTART);
  signal state, next_state : state_type := STARTUP;

  --Create a simple read buffer for each of the sequential bytes.
  type byte_buffer is array(natural range <>) of std_logic_vector(7 downto 0);
  signal read_buffer : byte_buffer(7 downto 0);

  --Signal which stores the current index in the byte buffer.
  signal current_byte_number      : integer range 8 downto 0   := 0;


begin

  --
  -- Instantiate our I2C controller.
  --
  I2C_CONTROLLER:
  entity i2c_master 
  generic map(
    input_clk => 50_000_000, --Our system clock speed, 50MHz.
    bus_clk   => 100_000
  )  
  port map(
		clk       => clk,
		reset_n   => not reset,
		ena       => transaction_active,
		addr      => address,
		rw        => reading,
		data_wr   => data_to_write,
		busy      => controller_in_use,
		data_rd   => last_read_data,
		ack_error => open,
		sda       => sda,
		scl       => scl
	);

  --
  -- Edge detect for the I2C controller's "in use" signal.
  --
  -- A rising edge of this signal denotes that the controller has accepted our data,
  -- and allows progression of our FSM.
  --
  controller_was_in_use    <= controller_in_use when rising_edge(clk);
  controller_accepted_data <= controller_in_use and not controller_was_in_use;

  --
  -- Output mappings.
  -- The output from the light sensor is recieved as a block of eight bytes,
  -- this breaks that block into Clear/RGB data.
  --
  clear_intensity(15 downto 8) <= read_buffer(1);
  clear_intensity(7  downto 0) <= read_buffer(0);
  red_intensity(15 downto 8)   <= read_buffer(3);
  red_intensity(7  downto 0)   <= read_buffer(2);
  green_intensity(15 downto 8) <= read_buffer(5);
  green_intensity(7  downto 0) <= read_buffer(4);
  blue_intensity(15 downto 8)  <= read_buffer(7);
  blue_intensity(7  downto 0)  <= read_buffer(6);


  --
  -- Main control FSM for the I2C light sensor.
  --
  CONTROL_FSM:
  process(clk)
  begin

    -- If our reset signal is being driven, restar the FSM.
    if reset = '1' then
      state <= state_type'left;

    elsif rising_edge(clk) then

      --Keep the following signals low unless asserted.
      --(This also prevents us from inferring additional memory.)
      data_to_write      <= (others => '0');


      case state is

        --
        -- Wait state.
        -- Waits for the I2C controller to become ready.
        --
        when STARTUP =>

          if controller_in_use = '0' then
            state <= SEND_POWER_COMMAND;
          end if;

        --
        -- First power-on state.
        -- Sets up the initial I2C communication that will enable the device's internal ADC.
        --
        when SEND_POWER_COMMAND =>
          
          --Set up the device to write the first byte of the setup command.
          transaction_active <= '1';
          reading      <= write;

          --Select the device's primary control register.
          data_to_write      <= select_control_register;

          --Wait here for the I2C controller to accept the new transmission, and become busy.
          if controller_accepted_data = '1' then
            state <= TURN_POWER_ON;
          end if;

        --
        -- Second power-on state.
        -- Continues the ADC enable communication.
        --
        when TURN_POWER_ON =>

          --And turn the device's enable on.
          data_to_write      <= power_on;

          --Once the controller has accepted this data,
          --move to the core sensor reading routine.
          if controller_accepted_data = '1' then
            state <= WAIT_BEFORE_READING;
          end if;


        --
        -- Wait for the transmitter to become ready
        -- before starting a second TWI transaction.
        --
        when WAIT_BEFORE_READING =>

          --Ensure we are not transmitting during for a
          --least a short period between readings.
          transaction_active  <= '0';
          current_byte_number <= 0;

          --Wait for the transmitter to become idle.
          if controller_in_use = '0' then
            state <= SEND_READ_COMMAND;
          end if;


        --
        -- Send the "read" command.
        -- This sets up a multi-byte read from the ADC sample register.
        --
        when SEND_READ_COMMAND =>

          --Set up the device to write to the command register,
          --indicating that we want to read multiple bytes from the ADC register.
          transaction_active      <= '1';
          reading                 <= write;
          current_byte_number     <= 0;
          

          --Select the device's primary control register.
          data_to_write      <= read_color_values;

          --Once the controller has accepted the command,
          --move to the state where we'll read from the device itself.
          if controller_accepted_data = '1' then
            state <= START_READ;
          end if;


        --
        -- Start a read of a single byte of ADC data.
        -- In this state, we set up our read data, and wait for the
        -- light sensor to accept it.
        --
        when START_READ =>

          --Set up the device to write to the command register,
          --indicating that we want to read multiple bytes from the ADC register.
          transaction_active      <= '1';
          reading                 <= read;

          --Wait for the controller to accept the read instruction.
          if controller_accepted_data = '1' then
           
            --If we've just initiated our final read, finish the read
            --and then start the read again from the beginning.
            if current_byte_number = read_buffer'high then
              state <= FINISH_READ_AND_RESTART;

            --Otherwise, finish the read, but keep populating the buffer.
            else
              state <= FINISH_READ_AND_CONTINUE;

            end if;
          end if;

        --
        -- Finish a read of a single byte of ADC data,
        -- and then continue reading.
        --
        when FINISH_READ_AND_CONTINUE =>

          --Wait for the I2C controller to finish reading...
          if controller_in_use = '0' then

            --...capture the read result.
            read_buffer(current_byte_number) <= last_read_data;

            --... move to the next spot in the read buffer.
            current_byte_number <= current_byte_number + 1;

            ---... and finish reading.
            state <= START_READ;

          end if;

        
        --
        -- Finish a read of a single byte of ADC data,
        -- and then restart from the beginning of the buffer.
        --
        when FINISH_READ_AND_RESTART =>

          --Since we're not going to continue reading,
          --allow the transaction to end.
          transaction_active <= '0';

          --Wait for the I2C controller to finish reading...
          if controller_in_use = '0' then

            --...capture the read result.
            read_buffer(current_byte_number) <= last_read_data;

            ---... and restart the process.
            state <= WAIT_BEFORE_READING;

          end if;



        end case; 
      end if;
    end process;


  end Behavioral;

