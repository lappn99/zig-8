const std = @import("std");
const Stack = @import("Stack.zig").Stack;
const scr = @import("Screen.zig");
const Screen = @import("Screen.zig").Screen;
const Timer = @import("Timer.zig").Timer;
const fs = std.fs;
const rand = std.rand;
const Allocator = std.mem.Allocator;
const Keyboard = @import("Keyboard.zig").Keyboard;
pub const Chip8Error = error{
    Chip8InitError,
    ProgramOpenError,
    ProgramTooLarge,
    CouldNotFindProgram,
    IllegalInstruction
};



var prng : std.rand.Xoroshiro128 = undefined;



pub const Chip8 = struct{
    V: []u16,
    I: u16 = 0,
    SP: u16 = 0,
    PC: u16 = 0x200,
    delay: *u16 = undefined,
    sound: u8 = 0,
    memory: []u8,
    screenMemory: []u8,
    stack: Stack,
    key: u8 = 0,
    allocator : std.heap.ArenaAllocator,
    instructionSet : InstructionSet,
    screen: Screen,
    stopExecution:bool = false,
    delayTimer : Timer = undefined,
    

    pub fn init() Chip8Error!Chip8 {

        //var heap :[32 + 4096 + (64*32) + 32] u8 = undefined;
        
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        
        var allocator = &arena.allocator;
        

        errdefer{
            std.debug.print("Error initialzing chip8\n",.{});
            arena.deinit();
        }

        var register = allocator.alloc(u16, 16) catch|err|{

            return Chip8Error.Chip8InitError;
        };
        var mem = allocator.alloc(u8, 4096) catch|err|{
            return Chip8Error.Chip8InitError;
        };
        var screenMemory = allocator.alloc(u8, 64*32) catch|err|{
            return Chip8Error.Chip8InitError;
        };
        
       var stack : Stack = Stack.init(16) catch |err|{
           return Chip8Error.Chip8InitError;
        };
        
        var delay : *u16= allocator.create(u16) catch |err|{
            return Chip8Error.Chip8InitError;
        };

        
        for (register) |v, i|{
            register[i] = 0;
        }
        for (mem) |v,i|{
            mem[i] = 0;
        }
        for(screenMemory) |v,i|{
            screenMemory[i] = 0;
        }
        
       
        prng = rand.DefaultPrng.init(blk: {
            var seed : u64 = undefined;
            std.os.getrandom(std.mem.asBytes(&seed)) catch |err|{
                break: blk 0;
            };
            break: blk seed;
        });

        var device = Chip8{
            .V = register,
            .memory = mem,
            .screenMemory = screenMemory,
            .allocator = arena,
            .instructionSet = InstructionSet.init(),
            .stack = stack,
            .screen = Screen.init(1280,720),
            .delay = delay
            
        };
        

        device.delayTimer = Timer.init(device.delay,60);
        Keyboard.init(device.screen.window);
        try device.fillInstructionSet();

        return  device;

    }

    pub fn deinit(self: *Chip8) void {
        self.allocator.deinit();
        self.screen.deinit();
        self.stack.deinit();
    }



    pub fn loadProgram(self:*Chip8,rom: []const u8 ) Chip8Error!u64{
        
        std.debug.print("\nLoading program: {s}", .{path});
        var file =  fs.openFileAbsolute(path, fs.File.OpenFlags{.read = true,.write=false}) catch |err|{
            return Chip8Error.ProgramOpenError;
        };
        var size:u64 =  file.getEndPos() catch |err| {
            return Chip8Error.ProgramOpenError;
        };
        std.debug.print("Program {s} size(bytes): {d} \n",.{path,size});

        if(size > 0xDFF){
            return Chip8Error.ProgramTooLarge;
        }

        defer file.close();
        
        const result = file.preadAll(self.memory[0x200..],0) catch |err|{
            return Chip8Error.ProgramOpenError;
        };
        return size;

    }

    pub fn loadRom(self: *Chip8, rom: []const u8) Chip8Error!void{
        
        if(rom.len > 0xDFF){
            return Chip8Error.ProgramTooLarge;
        }
        std.mem.copy(u8,self.memory[0x200..],rom);
        std.debug.print("Read {d} size program\n",.{rom.len});
    }

    fn fillInstructionSet(self: *Chip8) Chip8Error!void{
        
        self.instructionSet.set[0] = Operation { .func = sysInstruction};
        self.instructionSet.set[1] = Operation { .func = jump};
        self.instructionSet.set[2] = Operation { .func = call};
        self.instructionSet.set[3] = Operation{.func = skipEqual};
        self.instructionSet.set[4] = Operation{.func = skipNotEqual};
        self.instructionSet.set[5] = Operation{.func = skipEqualReg};
        self.instructionSet.set[6] = Operation{.func = load};
        self.instructionSet.set[7] = Operation{.func = addReg};
        self.instructionSet.set[8] = Operation{.func = bitRegOperations};
        self.instructionSet.set[9] = Operation{.func = skipNotEqualReg};
        self.instructionSet.set[0xA] = Operation{.func = loadIAddr};
        self.instructionSet.set[0xB] = Operation{.func = jumpRegZero};
        self.instructionSet.set[0xC] = Operation{.func = rnd};
        self.instructionSet.set[0xD] = Operation{.func = draw};
        self.instructionSet.set[0xE] = Operation{.func = skpKey};
        self.instructionSet.set[0xF] = Operation{.func = misc};


    }

    fn sysInstruction(self: *Chip8,data : u16) InstructionError!void{
        const lowerByte = data & 0x00FF;
        
        try switch(data){
            0x00E0 => clear(self),
            0x00EE => ret(self),

            else => return InstructionError.NotImplemented,
        };
        

    }

    pub fn executeInstruction(self: *Chip8,instr : u16) InstructionError!void{
        const idx = ((instr & 0xF000) >> 8) >> 4;

        try self.instructionSet.set[idx].func(self,instr);
        

    }

    fn loadIntoRegister(self: *Chip8, x: u16, val: u16) void{
        self.V[x] = val;

    }

    pub fn run(self: *Chip8, programSize: u64) void{
        
        while((self.PC < 0x200 + programSize) and !self.screen.shouldClose()){
            if(self.stopExecution == false){
                var instruction : u16 = 0;
                instruction = ((instruction | self.memory[self.PC]) <<8) | self.memory[self.PC + 1]; 

                std.debug.print("{x} {x} \t", .{self.PC,instruction});
                self.executeInstruction(instruction) catch |err|{
                    switch(err) {
                        error.NotImplemented => {
                            std.debug.print("Instruction {d} not implemented, stopping execution\n", .{instruction});
                            self.stopExecution = true;
                        },
                        else => {
                            std.debug.print("Error executing instruction: {d}, at address {d}, exiting", .{instruction,self.PC});
                            self.stopExecution = true;
                        }
                    }

                };
                self.PC += 2;
            }
            
            
            self.screen.setPixels(self.screenMemory);
            self.screen.render();
            self.screen.pollEvents();
            self.key = Keyboard.currentKeyPressed;
            self.delayTimer.update();
            
            
        }
    }


    
    pub fn startTimer(self : *Chip8, register: *u8,frequency: u8) void{

        const rate = 1.0/@intToFloat(f32,frequency);
        while(true){
            var lastUpdate = std.time.milliTimestamp();
            suspend;
            var timestamp = std.time.milliTimestamp();
            std.debug.print("{d}", .{timestamp - lastUpdate});


        }

    }

    fn clear(self: *Chip8) InstructionError!void{
        for(self.screenMemory) |v,i|{
            self.screenMemory[i] = 0;
        }
        std.debug.print("CLR\n",.{});
    }

    fn ret(self: *Chip8) InstructionError!void{
        
        self.PC = self.stack.pop() catch |err|{
            return InstructionError.ExecutionError;
        };
        std.debug.print("RET \t {d}\n",.{self.PC});
        
    }

    fn jump(self: *Chip8, data : u16) InstructionError!void {
        const addr : u16 = data & 0x0FFF;
        std.debug.print("JMP \t {d}\n",.{addr});
        self.PC = addr;
        self.PC -= 2;
        

    }

    fn call(self:*Chip8, data: u16) InstructionError!void{
        const addr : u16 = data & 0x0FFF;
        std.debug.print("CALL \t {d}\n", .{addr});
        self.stack.push(self.PC) catch |err|{
            return InstructionError.ExecutionError;
        };
        self.PC = addr - 0x2;
    }

    fn skipNotEqual(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const kk =  data & 0x00FF;

        std.debug.print("SNE \t V{d} != {d}\n", .{x,kk});
        if(self.V[x] != kk){
            self.PC +=2;
        }

    }

    fn skipEqual(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const kk =  data & 0x00FF;

        std.debug.print("SE \t V{d} = {d}\n", .{x,kk});
        if(self.V[x] == kk){
            self.PC +=2;
        }
        
    }

    fn skipEqualReg(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const y = (data & 0x00F0) >> 4;
        std.debug.print("SE \t V{d} = V{d}\n", .{x,y});
        if(self.V[x] == self.V[y]){
            self.PC += 2;
        }
    }

    fn load(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const kk =  data & 0x00FF;

        std.debug.print("LD \t V{d},{d}\n",.{x,kk});
        self.V[x] = kk;

    }

    fn addReg(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const kk =  data & 0x00FF;

        std.debug.print("ADD \t V{d},{d}\n",.{x,kk});
        self.V[x] += kk;


    }

    

    fn bitRegOperations(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const y = (data & 0x00F0) >> 4;
        const op = data & 0x000F;

        const result = switch(op){
            0 => blk: {
                std.debug.print("LD \t V{d},V{d}\n",.{x,y});
                break: blk self.V[y];
            },
            1 =>  blk : {
                std.debug.print("OR \t V{d},V{d}\n",.{x,y});
                break: blk self.V[x] | self.V[y];
            },
            2 => blk : {
                std.debug.print("AND \t V{d},V{d}\n",.{x,y});
                break: blk self.V[x] & self.V[y];
            },
            3 => blk: { 
                std.debug.print("XOR \t V{d},V{d}\n",.{x,y});
                break: blk self.V[x] ^ self.V[y];
            },
            4 => blk :{
                std.debug.print("ADD \t V{d},V{d}\n",.{x,y});
                const result = self.V[x] + self.V[y];
                if(result > 255){
                    self.V[0xF] = 1;
                }
                break: blk result & 0xFF;

            },
            5=> blk :{
                std.debug.print("SUB \t V{d},V{d}\n",.{x,y});
                const result = self.V[x] - self.V[y];
                if(self.V[x] > self.V[y]){
                    self.V[0xF] = 1;
                }
                break: blk result;
            },
            6=> blk:{
                std.debug.print("SHR \t V{d}, 1\n",.{x});
                const result = self.V[x] >> 1;
                if(self.V[x] & 1 == 1){
                    self.V[0xF] = 1;
                }
                else{
                    self.V[0xF] = 0;
                }
                break: blk result;
            },
            7 => blk:{
                std.debug.print("SUBN \t V{d},V{d}\n",.{x,y});
                const result = self.V[y] - self.V[x];
                if(self.V[y] > self.V[x]){
                    self.V[0xF] = 1;
                }
                else{
                    self.V[0xF] = 0;
                }
                break: blk result;
            },
            0xE => blk:{
                std.debug.print("SHL \t V{d}, 1\n",.{x});
                const result = self.V[x] * 2;
                if(self.V[x] & 1 == 1){
                    self.V[0xF] = 1;
                }
                else{
                    self.V[0xF] = 0;
                }
                break: blk result;
            },
            else => blk:{
                const result = 0;
                std.debug.print("Unknown operation\n",.{});
                break:blk result;
            }
        };
        
        self.V[x] = result;
        


    }

    fn skipNotEqualReg(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const y = (data & 0x00F0) >> 4;
        std.debug.print("SNE \t V{d} = V{d}\n", .{x,y});
        if(self.V[x] != self.V[y]){
            self.PC += 2;
        }

    }

    fn loadIAddr(self: *Chip8, data:u16) InstructionError!void{
        const nnn =  data & 0x0FFF;
        std.debug.print("LD \t I, {d}\n", .{nnn});
        self.I = nnn;
    }

    fn jumpRegZero(self: *Chip8, data:u16) InstructionError!void{
        const addr : u16 = data & 0x0FFF;
        std.debug.print("JMP \t {d} + V0\n",.{addr});
        self.PC = addr + self.V[0];
    }

    fn rnd(self: *Chip8, data:u16) InstructionError!void{
        const random = &prng.random;
        const x = (data & 0x0F00) >> 8;
        const kk =  data & 0x00FF;

        self.V[x] = random.int(u8) & kk;


    }

    fn draw(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const y = (data & 0x00F0) >> 4;
        const n = data & 0x000F;
        var idx = self.V[x] + scr.pixel_screen_width * self.V[ y];
        const spriteData :[]u8 = self.memory[self.I..self.I + n];
        for(spriteData) |*sprite,i|{
            //std.debug.print("{d}", .{sprite});
            for( [_] u8{7,6,5,4,3,2,1,0}) |bit|{
                
                var spriteBit : u8 = sprite.*  & 1 ;
                
                
                self.screenMemory[ idx + bit ] = spriteBit ^ self.screenMemory[idx + bit ];
                
                sprite.* /= 2;
            }
            idx += 8;
            
        }
        std.debug.print("DRW \t x{d}, y{d}, {x}\n", .{self.V[x],self.V[y],n});
        

    }


    pub fn skpKey(self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const lower = data & 0x00FF;
        switch(lower) {
            0x9E =>{
                if(self.key == self.V[x]){
                    self.PC += 2;
                }
                std.debug.print("SKP K = V{d}\n", .{x});
            },
            0xA1 =>{
                std.debug.print("SKP K != V{d}\n", .{x});
                if(self.key != self.V[x]){
                    self.PC += 2;
                }
            },
            else =>{ return InstructionError.NotImplemented;}
        }
        
    }

    pub fn misc (self: *Chip8, data:u16) InstructionError!void{
        const x = (data & 0x0F00) >> 8;
        const lower = data & 0x00FF;
        switch(lower) {
            0x07 => {
                    self.V[x] = self.delay.*; 
                    std.debug.print("LD \t DT, V{d}\n", . {x});

                },
            0x0A => {
                self.key = 0xFF;
                std.debug.print("LD \t V{d}, Key\n", .{x});
                while(self.key == 0xFF){
                    Keyboard.blockForEvents();
                    self.key = Keyboard.currentKeyPressed;
                }
                self.V[x] = self.key;
            },
            0x15 => self.delay.* = self.V[x],
            //TODO : 0x18
            0x1E =>  {
                std.debug.print("ADD \t I, V{d}\n", .{x});
                self.I += self.V[x];
            },
            else => {
                std.debug.print("UNHANDLED\n", .{});
            }



            
        }

    }



};

pub const InstructionError = error{
    NotImplemented,
    ExecutionError
};

pub const Operation = union{
    func : fn(*Chip8, u16) InstructionError!void,
    

};



pub const InstructionSet = struct{
    set : [16]Operation,

    pub fn init() InstructionSet{

        const set = [_]Operation{Operation{.func = notImplemented}} ** 16;



        return InstructionSet{
            .set = set
        };

    }

    pub fn notImplemented(self: *Chip8, ins:u16 ) InstructionError!void{
        return InstructionError.NotImplemented;
    }
    


};