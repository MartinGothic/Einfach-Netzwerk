using System;
using System.Security.Cryptography;

namespace EinfachNetzwerk
{
    internal static class NetworkPasswordGenerator
    {
        // Only an explicit password-generation action calls this helper.
        internal static string Create()
        {
            const string upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
            const string lower = "abcdefghijkmnopqrstuvwxyz";
            const string digits = "23456789";
            const string symbols = "!@#$%*-_+";
            const string alphabet = upper + lower + digits + symbols;
            char[] value = new char[20];
            using (RandomNumberGenerator random = RandomNumberGenerator.Create())
            {
                value[0] = upper[Next(random, upper.Length)];
                value[1] = lower[Next(random, lower.Length)];
                value[2] = digits[Next(random, digits.Length)];
                value[3] = symbols[Next(random, symbols.Length)];
                for (int i = 4; i < value.Length; i++) value[i] = alphabet[Next(random, alphabet.Length)];
                for (int i = value.Length - 1; i > 0; i--)
                {
                    int position = Next(random, i + 1);
                    char temporary = value[i]; value[i] = value[position]; value[position] = temporary;
                }
            }
            string result = new String(value);
            Array.Clear(value, 0, value.Length);
            return result;
        }
        private static int Next(RandomNumberGenerator random, int bound)
        {
            byte[] value = new byte[1];
            int limit = 256 - 256 % bound;
            do { random.GetBytes(value); } while (value[0] >= limit);
            return value[0] % bound;
        }
    }
}
